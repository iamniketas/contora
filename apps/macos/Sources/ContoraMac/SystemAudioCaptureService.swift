import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AudioToolbox

enum SystemAudioCaptureServiceError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case alreadyRunning
    case notRunning

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required for system audio capture."
        case .displayNotFound:
            return "No display available for ScreenCaptureKit content filter."
        case .alreadyRunning:
            return "System audio capture is already running."
        case .notRunning:
            return "System audio capture is not running."
        }
    }
}

/// Foundation for macOS system-level audio capture via ScreenCaptureKit.
///
/// Notes:
/// - macOS does not provide global loopback API equivalent to WASAPI.
/// - ScreenCaptureKit is the native path for capturing system output audio.
/// - Caller must request Screen Recording permission.
final class SystemAudioCaptureService: NSObject {
    private let queue = DispatchQueue(label: "contora.system-audio.capture")
    private let stateQueue = DispatchQueue(label: "contora.system-audio.state")

    private var stream: SCStream?
    private var isRunning = false
    private var startTime: Date?

    private var buffered16kScratchFile: PCMFloatScratchFileBuffer?
    private var nativeSamplesCount = 0
    private var nativeSampleRate: Double = 48_000

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func startCapture() async throws {
        let alreadyRunning = stateQueue.sync { isRunning }
        guard !alreadyRunning else {
            throw SystemAudioCaptureServiceError.alreadyRunning
        }

        guard Self.hasPermission() || Self.requestPermission() else {
            throw SystemAudioCaptureServiceError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureServiceError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        stateQueue.sync {
            buffered16kScratchFile?.discard()
            buffered16kScratchFile = try? PCMFloatScratchFileBuffer(prefix: "contora-system")
            nativeSamplesCount = 0
            nativeSampleRate = Double(config.sampleRate)
            startTime = Date()
            isRunning = true
            self.stream = stream
        }
    }

    func stopCapture() async throws -> AudioCaptureResult {
        let streamToStop: SCStream? = stateQueue.sync {
            guard isRunning, let stream else {
                return nil
            }
            return stream
        }

        guard let streamToStop else {
            throw SystemAudioCaptureServiceError.notRunning
        }

        try await streamToStop.stopCapture()

        let snapshot: (scratchFile: PCMFloatScratchFileBuffer?, nativeCount: Int) = stateQueue.sync {
            self.stream = nil
            isRunning = false
            startTime = nil
            let scratchFile = buffered16kScratchFile
            buffered16kScratchFile = nil
            let nativeCount = nativeSamplesCount
            nativeSamplesCount = 0
            return (scratchFile, nativeCount)
        }

        let samples16k = try snapshot.scratchFile?.finishReadingAllSamples() ?? []
        let duration = Double(samples16k.count) / 16_000.0

        return AudioCaptureResult(
            samples16kMono: samples16k,
            durationSeconds: duration,
            nativeSamplesCount: snapshot.nativeCount
        )
    }

    func elapsedSeconds() -> Double {
        stateQueue.sync {
            guard isRunning, let startTime else {
                return 0
            }
            return Date().timeIntervalSince(startTime)
        }
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ContoraMac] SCStream stopped with error: \(error.localizedDescription)")
        isRunning = false
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return
        }

        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        if frames <= 0 {
            return
        }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 0,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return
        }

        let monoSamples = extractMonoSamples(from: audioBufferList, frames: frames, asbd: asbd.pointee)
        guard !monoSamples.isEmpty else {
            return
        }

        stateQueue.sync {
            nativeSampleRate = asbd.pointee.mSampleRate
            nativeSamplesCount += monoSamples.count
            let downsampled = AudioCaptureService.resampleTo16k(samples: monoSamples, nativeSampleRate: asbd.pointee.mSampleRate)
            do {
                try buffered16kScratchFile?.append(samples: downsampled)
            } catch {
                // Keep capture running even if one scratch append fails.
            }
        }
    }

    private func extractMonoSamples(from audioBufferList: AudioBufferList, frames: Int, asbd: AudioStreamBasicDescription) -> [Float] {
        let channels = Int(max(1, asbd.mChannelsPerFrame))
        var mono = [Float](repeating: 0, count: frames)
        let format = asbd.mFormatID

        guard format == kAudioFormatLinearPCM else {
            return []
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        var list = audioBufferList
        withUnsafeMutablePointer(to: &list) { ptr in
            let buffers = UnsafeMutableAudioBufferListPointer(ptr)
            guard let first = buffers.first, let rawData = first.mData else {
                return
            }

            if isFloat && bitsPerChannel == 32 {
                let data = rawData.bindMemory(to: Float.self, capacity: frames * channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += data[frame * channels + channel]
                    }
                    mono[frame] = sum / Float(channels)
                }
                return
            }

            if isSignedInteger && bitsPerChannel == 16 {
                let data = rawData.bindMemory(to: Int16.self, capacity: frames * channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let value = Float(data[frame * channels + channel]) / 32768.0
                        sum += value
                    }
                    mono[frame] = sum / Float(channels)
                }
                return
            }
        }

        return []
    }
}
