import Foundation

@main
struct ProcessServiceSmokeTest {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeTestError.invalidArguments
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-process-service-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioURL = root.appendingPathComponent("audio.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)

        let progressRecorder = ProgressRecorder()
        let service = FasterWhisperProcessTranscriptionService(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            modelName: "test",
            language: "en",
            enableDiarization: false
        )
        let transcript = try service.transcribe(
            audioFileURL: audioURL,
            outputDirectory: root,
            onProgress: { progress in
                progressRecorder.append(progress.fraction)
            }
        )

        guard transcript == "smoke-test transcript" else {
            throw SmokeTestError.unexpectedTranscript(transcript)
        }
        guard progressRecorder.values() == [0.1, 0.55, 1.0] else {
            throw SmokeTestError.unexpectedProgress
        }

        let cancellationFlag = FasterWhisperCancellationFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            cancellationFlag.cancel()
        }
        let cancellationService = FasterWhisperProcessTranscriptionService(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            modelName: "cancel-test",
            language: "en",
            enableDiarization: false
        )
        let cancellationStartedAt = Date()
        do {
            _ = try cancellationService.transcribe(
                audioFileURL: audioURL,
                outputDirectory: root,
                isCancelled: { cancellationFlag.isCancelled() }
            )
            throw SmokeTestError.cancellationDidNotStopProcess
        } catch is CancellationError {
            guard Date().timeIntervalSince(cancellationStartedAt) < 5 else {
                throw SmokeTestError.cancellationWasTooSlow
            }
        }
        print("Process service smoke test passed")
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func append(_ value: Double) {
        lock.withLock { recorded.append(value) }
    }

    func values() -> [Double] {
        lock.withLock { recorded }
    }
}

enum SmokeTestError: Error {
    case invalidArguments
    case unexpectedTranscript(String)
    case unexpectedProgress
    case cancellationDidNotStopProcess
    case cancellationWasTooSlow
}
