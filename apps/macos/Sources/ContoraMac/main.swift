import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import ApplicationServices
import Combine
import Foundation
import UniformTypeIdentifiers

enum PermissionStatus: String {
    case unknown = "Unknown"
    case granted = "Granted"
    case denied = "Denied"
}

enum AudioCaptureError: LocalizedError {
    case alreadyRunning
    case notRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Recording is already running"
        case .notRunning:
            return "Recording is not running"
        }
    }
}

struct AudioCaptureResult {
    let samples16kMono: [Float]
    let durationSeconds: Double
    let nativeSamplesCount: Int
}

enum CaptureSourceMode: String, CaseIterable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"
    case mixed = "System + Microphone"
}

enum RecordingStoragePolicy: String, CaseIterable, Identifiable, Codable {
    case wavOnly = "WAV Only"
    case wavPlusM4A = "WAV + M4A"
    case m4aOnly = "M4A Only"

    var id: String { rawValue }
}

enum TranscriptionError: LocalizedError {
    case badResponse
    case serverError(statusCode: Int, message: String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Invalid response from transcription server."
        case let .serverError(statusCode, message):
            return "Transcription server error \(statusCode): \(message)"
        case .invalidPayload:
            return "Transcription payload is missing text."
        }
    }
}

enum RecordingArchiveError: LocalizedError {
    case appSupportDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .appSupportDirectoryUnavailable:
            return "Application Support directory is unavailable."
        }
    }
}

enum AudioImportError: LocalizedError {
    case unsupportedFormat
    case readFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Imported audio format is not supported."
        case .readFailed:
            return "Failed to read imported audio file."
        }
    }
}

enum VideoImportError: LocalizedError {
    case ffmpegNotFound
    case extractionFailed(message: String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg is not installed or not available in PATH."
        case let .extractionFailed(message):
            return "Failed to extract audio from video: \(message)"
        case .outputMissing:
            return "ffmpeg finished without producing an output audio file."
        }
    }
}

struct RuntimeDiagnostics {
    var ffmpegStatus = "Not checked"
    var ffmpegPath = ""
    var ffmpegVersion = ""
    var sharedRuntimeRoot = ""
    var sharedRuntimeRootStatus = "Unknown"
    var whisperExecutablePath = ""
    var whisperExecutableStatus = "Unknown"
    var modelsDirectoryPath = ""
    var modelsDirectoryStatus = "Unknown"
    var sharedConfigPath = ""
    var sharedConfigStatus = "Unknown"
    var activeBackend = ""
    var sharedMLXToolkitRoot = ""
    var sharedMLXToolkitStatus = "Unknown"
    var sharedMLXLogPath = ""
    var sharedModelCatalogPath = ""
    var sharedModelCatalogStatus = "Unknown"
    var sharedModelCatalogSummary = ""
}

struct ContoraSession: Identifiable, Hashable {
    struct Speaker: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    struct Segment: Identifiable, Hashable {
        let id: String
        let startSeconds: Double
        let endSeconds: Double
        let speakerID: String
        let text: String

        var timestampDisplay: String {
            let total = Int(startSeconds)
            let minutes = total / 60
            let seconds = total % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    struct Metadata: Hashable {
        let createdAt: String?
        let mode: String?
        let language: String?
        let endpoint: String?
        let audioSeconds: Double?
        let success: Bool?
        let errorMessage: String?
    }

    let id: String
    let title: String
    let createdAt: Date
    let recordingURL: URL
    let transcriptURL: URL?
    let jsonURL: URL?
    let transcriptPreview: String
    let metadata: Metadata
    let speakers: [Speaker]
    let segments: [Segment]
}

struct EditableSessionSegment: Identifiable, Hashable {
    let id: String
    let startSeconds: Double
    let endSeconds: Double
    let speakerID: String
    var speakerName: String
    var text: String

    var timestampDisplay: String {
        let total = Int(startSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct ContoraSessionManifest: Codable {
    struct Files: Codable {
        let recordingWAV: String?
        let recordingM4A: String?
        let transcriptTXT: String?
        let transcriptJSON: String?
    }

    struct Capture: Codable {
        let sourceMode: String
        let audioSeconds: Double?
        let sampleRate: Int
        let channels: Int
    }

    struct Transcription: Codable {
        struct Speaker: Codable {
            let id: String
            let displayName: String
        }

        struct Segment: Codable {
            let id: String
            let startSeconds: Double
            let endSeconds: Double
            let speakerID: String
            let text: String
        }

        let status: String
        let backend: String?
        let endpoint: String?
        let language: String?
        let mode: String?
        let durationSeconds: Double?
        let errorMessage: String?
        let speakers: [Speaker]?
        let segments: [Segment]?
    }

    let schemaVersion: String
    let sessionID: String
    let title: String
    let createdAt: String
    let updatedAt: String
    let files: Files
    let capture: Capture
    let transcription: Transcription?
}

enum SessionLibraryError: LocalizedError {
    case recordingsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .recordingsDirectoryUnavailable:
            return "Recordings directory is unavailable."
        }
    }
}

final class SessionLibraryService {
    private let fileManager = FileManager.default
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let segmentParser = TranscriptSegmentParser()

    func loadSessions() throws -> [ContoraSession] {
        let directory = try RecordingArchiveService.recordingsDirectoryURL()
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let manifestFiles = urls.filter { $0.lastPathComponent.hasSuffix(".session.json") }
        let manifestSessions = manifestFiles.compactMap { loadManifestSession(from: $0, rootDirectory: directory) }
        let manifestRecordingNames = Set(manifestFiles.flatMap { manifestAudioFileNames(from: $0) })

        let audioFiles = urls.filter { ["wav", "m4a"].contains($0.pathExtension.lowercased()) }
        let sessions = try audioFiles.compactMap { audioURL -> ContoraSession? in
            if manifestRecordingNames.contains(audioURL.lastPathComponent) {
                return nil
            }
            let baseURL = audioURL.deletingPathExtension()
            let txtURL = baseURL.appendingPathExtension("txt")
            let jsonURL = baseURL.appendingPathExtension("json")
            let transcriptURL = fileManager.fileExists(atPath: txtURL.path) ? txtURL : nil
            let metadataURL = fileManager.fileExists(atPath: jsonURL.path) ? jsonURL : nil

            let transcriptText = transcriptURL.flatMap {
                try? String(contentsOf: $0, encoding: .utf8)
            } ?? ""

            let metadata = loadMetadata(from: metadataURL)
            let resourceValues = try audioURL.resourceValues(forKeys: [.contentModificationDateKey])
            let createdAt = resourceValues.contentModificationDate ?? Date.distantPast
            let title = baseURL.lastPathComponent
            let parsed = segmentParser.parseSpeakersAndSegments(from: transcriptText)

            return ContoraSession(
                id: title,
                title: title,
                createdAt: createdAt,
                recordingURL: audioURL,
                transcriptURL: transcriptURL,
                jsonURL: metadataURL,
                transcriptPreview: makePreview(from: transcriptText),
                metadata: metadata,
                speakers: parsed.speakers,
                segments: parsed.segments
            )
        }

        return (manifestSessions + sessions).sorted { $0.createdAt > $1.createdAt }
    }

    private func loadManifestSession(from manifestURL: URL, rootDirectory: URL) -> ContoraSession? {
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? decoder.decode(ContoraSessionManifest.self, from: data)
        else {
            return nil
        }

        let recordingURL = resolveRecordingURL(files: manifest.files, rootDirectory: rootDirectory)
        guard let recordingURL, fileManager.fileExists(atPath: recordingURL.path) else {
            return nil
        }

        let transcriptURL = manifest.files.transcriptTXT.map { rootDirectory.appendingPathComponent($0) }
        let transcriptExists = transcriptURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        let transcriptText = transcriptExists.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let jsonURL = manifest.files.transcriptJSON.map { rootDirectory.appendingPathComponent($0) }
        let parsedDate = ISO8601DateFormatter().date(from: manifest.createdAt) ?? Date.distantPast
        let parsed = segmentParser.parseSpeakersAndSegments(from: transcriptText)
        let manifestSpeakers = manifest.transcription?.speakers?.map {
            ContoraSession.Speaker(id: $0.id, displayName: $0.displayName)
        }
        let manifestSegments = manifest.transcription?.segments?.map {
            ContoraSession.Segment(
                id: $0.id,
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds,
                speakerID: $0.speakerID,
                text: $0.text
            )
        }

        return ContoraSession(
            id: manifest.sessionID,
            title: manifest.title,
            createdAt: parsedDate,
            recordingURL: recordingURL,
            transcriptURL: transcriptExists,
            jsonURL: jsonURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil },
            transcriptPreview: makePreview(from: transcriptText),
            metadata: .init(
                createdAt: manifest.createdAt,
                mode: manifest.capture.sourceMode,
                language: manifest.transcription?.language,
                endpoint: manifest.transcription?.endpoint,
                audioSeconds: manifest.capture.audioSeconds,
                success: manifest.transcription?.status == "completed" ? true : (manifest.transcription?.status == "failed" ? false : nil),
                errorMessage: manifest.transcription?.errorMessage
            ),
            speakers: manifestSpeakers ?? parsed.speakers,
            segments: manifestSegments ?? parsed.segments
        )
    }

    private func resolveRecordingURL(files: ContoraSessionManifest.Files, rootDirectory: URL) -> URL? {
        if let wav = files.recordingWAV {
            let wavURL = rootDirectory.appendingPathComponent(wav)
            if fileManager.fileExists(atPath: wavURL.path) {
                return wavURL
            }
        }

        if let m4a = files.recordingM4A {
            let m4aURL = rootDirectory.appendingPathComponent(m4a)
            if fileManager.fileExists(atPath: m4aURL.path) {
                return m4aURL
            }
        }

        return nil
    }

    private func manifestAudioFileNames(from manifestURL: URL) -> [String] {
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? decoder.decode(ContoraSessionManifest.self, from: data)
        else {
            return []
        }

        return [manifest.files.recordingWAV, manifest.files.recordingM4A].compactMap { $0 }
    }

    private func loadMetadata(from jsonURL: URL?) -> ContoraSession.Metadata {
        guard
            let jsonURL,
            let data = try? Data(contentsOf: jsonURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .init(createdAt: nil, mode: nil, language: nil, endpoint: nil, audioSeconds: nil, success: nil, errorMessage: nil)
        }

        return .init(
            createdAt: object["created_at"] as? String,
            mode: object["mode"] as? String,
            language: object["language"] as? String,
            endpoint: object["endpoint"] as? String,
            audioSeconds: object["audio_seconds"] as? Double,
            success: object["success"] as? Bool,
            errorMessage: object["error"] as? String
        )
    }

    private func makePreview(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.isEmpty {
            return "No transcript yet."
        }

        return String(normalized.prefix(220))
    }
}

final class TranscriptSegmentParser {
    private let regex = try! NSRegularExpression(
        pattern: #"^\[(\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}\.\d{3})\]\s*(?:\[([^\]]+)\]:\s*)?(.*)$"#,
        options: []
    )

    func parseSpeakersAndSegments(from transcriptText: String) -> (speakers: [ContoraSession.Speaker], segments: [ContoraSession.Segment]) {
        let lines = transcriptText.components(separatedBy: .newlines)
        var segments: [ContoraSession.Segment] = []
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentSpeaker = "SPEAKER_00"
        var currentText = ""
        var currentHasSegment = false

        func flushCurrent() {
            let normalized = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentHasSegment, !normalized.isEmpty else {
                currentText = ""
                currentHasSegment = false
                return
            }

            segments.append(
                ContoraSession.Segment(
                    id: UUID().uuidString,
                    startSeconds: currentStart,
                    endSeconds: currentEnd,
                    speakerID: currentSpeaker,
                    text: normalized
                )
            )
            currentText = ""
            currentHasSegment = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range) {
                flushCurrent()
                currentStart = parseTime(match.string(in: trimmed, at: 1)) ?? 0
                currentEnd = parseTime(match.string(in: trimmed, at: 2)) ?? currentStart
                currentSpeaker = match.string(in: trimmed, at: 3) ?? "SPEAKER_00"
                currentText = match.string(in: trimmed, at: 4) ?? ""
                currentHasSegment = true
            } else if currentHasSegment {
                if !currentText.isEmpty {
                    currentText.append(" ")
                }
                currentText.append(trimmed)
            }
        }

        flushCurrent()

        let speakerIDs = Array(Set(segments.map(\.speakerID))).sorted()
        let speakers = speakerIDs.map { ContoraSession.Speaker(id: $0, displayName: $0) }
        return (speakers, segments)
    }

    private func parseTime(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 3 else { return nil }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return (hours * 3600) + (minutes * 60) + seconds
    }
}

private extension NSTextCheckingResult {
    func string(in source: String, at index: Int) -> String? {
        let range = range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }
}

enum WAVEncoder {
    static func makeWAVData(samples: [Float], sampleRate: UInt32) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        data.append("RIFF".data(using: .ascii)!)
        data.appendUInt32LE(riffSize)
        data.append("WAVE".data(using: .ascii)!)

        data.append("fmt ".data(using: .ascii)!)
        data.appendUInt32LE(16)
        data.appendUInt16LE(3)
        data.appendUInt16LE(channelCount)
        data.appendUInt32LE(sampleRate)
        data.appendUInt32LE(byteRate)
        data.appendUInt16LE(blockAlign)
        data.appendUInt16LE(bitsPerSample)

        data.append("data".data(using: .ascii)!)
        data.appendUInt32LE(dataSize)
        for value in samples {
            data.appendFloat32LE(value)
        }

        return data
    }
}

final class RecordingArchiveService {
    private let fileManager = FileManager.default
    private let keepLastCount = 3

    struct SessionIdentity {
        let sessionID: String
        let title: String
        let createdAt: Date
    }

    static func recordingsDirectoryURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecordingArchiveError.appSupportDirectoryUnavailable
        }

        return appSupport
            .appendingPathComponent("Contora", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    func saveRecording(samples16kMono: [Float], sampleRate: UInt32 = 16_000) throws -> (SessionIdentity, URL) {
        let recordingsDirectory = try makeRecordingsDirectory()
        let sessionID = "recording-\(timestampString())-\(UUID().uuidString.prefix(8))"
        let filename = "\(sessionID).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(filename)
        let createdAt = Date()

        let wavData = WAVEncoder.makeWAVData(samples: samples16kMono, sampleRate: sampleRate)
        try wavData.write(to: fileURL, options: .atomic)
        try pruneRecordings(in: recordingsDirectory)
        return (SessionIdentity(sessionID: sessionID, title: sessionID, createdAt: createdAt), fileURL)
    }

    func siblingCompressedURL(for recordingFileURL: URL) -> URL {
        recordingFileURL.deletingPathExtension().appendingPathExtension("m4a")
    }

    func saveSessionManifest(
        sessionID: SessionIdentity,
        recordingFileURL: URL,
        captureSourceMode: String,
        audioSeconds: Double,
        sampleRate: Int = 16_000,
        channels: Int = 1,
        recordingM4AURL: URL? = nil,
        transcriptTXT: URL? = nil,
        transcriptJSON: URL? = nil,
        transcription: ContoraSessionManifest.Transcription? = nil
    ) throws -> URL {
        let manifestURL = recordingFileURL.deletingPathExtension().appendingPathExtension("session.json")
        let formatter = ISO8601DateFormatter()
        let manifest = ContoraSessionManifest(
            schemaVersion: "1.0",
            sessionID: sessionID.sessionID,
            title: sessionID.title,
            createdAt: formatter.string(from: sessionID.createdAt),
            updatedAt: formatter.string(from: Date()),
            files: .init(
                recordingWAV: recordingFileURL.pathExtension.lowercased() == "wav" ? recordingFileURL.lastPathComponent : nil,
                recordingM4A: recordingM4AURL?.lastPathComponent ?? (recordingFileURL.pathExtension.lowercased() == "m4a" ? recordingFileURL.lastPathComponent : nil),
                transcriptTXT: transcriptTXT?.lastPathComponent,
                transcriptJSON: transcriptJSON?.lastPathComponent
            ),
            capture: .init(
                sourceMode: captureSourceMode,
                audioSeconds: audioSeconds,
                sampleRate: sampleRate,
                channels: channels
            ),
            transcription: transcription
        )
        let data = try JSONEncoder.prettyISO8601.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    func saveTranscriptJSON(
        for recordingFileURL: URL,
        transcriptText: String,
        mode: String,
        language: String,
        endpoint: String,
        audioSeconds: Double,
        postStopWaitSeconds: Double,
        transcriptionSeconds: Double?,
        success: Bool,
        errorMessage: String?
    ) throws -> URL {
        let jsonURL = recordingFileURL.deletingPathExtension().appendingPathExtension("json")
        let payload: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "recording_file": recordingFileURL.lastPathComponent,
            "mode": mode,
            "language": language,
            "endpoint": endpoint,
            "audio_seconds": audioSeconds,
            "post_stop_wait_seconds": postStopWaitSeconds,
            "transcription_seconds": transcriptionSeconds as Any,
            "success": success,
            "error": errorMessage as Any,
            "text": transcriptText
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: jsonURL, options: .atomic)
        return jsonURL
    }

    func saveTranscriptText(for recordingFileURL: URL, transcriptText: String) throws -> URL {
        let txtURL = recordingFileURL.deletingPathExtension().appendingPathExtension("txt")
        try transcriptText.write(to: txtURL, atomically: true, encoding: .utf8)
        return txtURL
    }

    func updateTranscriptJSONPreservingMetadata(for recordingFileURL: URL, transcriptText: String) throws -> URL {
        let jsonURL = recordingFileURL.deletingPathExtension().appendingPathExtension("json")
        var payload: [String: Any] = [:]
        if
            FileManager.default.fileExists(atPath: jsonURL.path),
            let data = try? Data(contentsOf: jsonURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            payload = object
        }

        payload["text"] = transcriptText
        payload["updated_at"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: jsonURL, options: .atomic)
        return jsonURL
    }

    private func makeRecordingsDirectory() throws -> URL {
        let dir = try Self.recordingsDirectoryURL()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pruneRecordings(in directory: URL) throws {
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let primaryAudio = fileURLs.filter { ["wav", "m4a"].contains($0.pathExtension.lowercased()) }
        if primaryAudio.count <= keepLastCount {
            return
        }

        let sorted = try primaryAudio.sorted { lhs, rhs in
            let lDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lDate > rDate
        }

        for old in sorted.dropFirst(keepLastCount) {
            try? fileManager.removeItem(at: old)
            let siblingJSON = old.deletingPathExtension().appendingPathExtension("json")
            let siblingTXT = old.deletingPathExtension().appendingPathExtension("txt")
            let siblingManifest = old.deletingPathExtension().appendingPathExtension("session.json")
            let siblingWAV = old.deletingPathExtension().appendingPathExtension("wav")
            let siblingM4A = old.deletingPathExtension().appendingPathExtension("m4a")
            try? fileManager.removeItem(at: siblingJSON)
            try? fileManager.removeItem(at: siblingTXT)
            try? fileManager.removeItem(at: siblingManifest)
            try? fileManager.removeItem(at: siblingWAV)
            try? fileManager.removeItem(at: siblingM4A)
        }
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

final class AudioCompressionService {
    func compressToM4A(wavURL: URL) async throws -> URL {
        let outputURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: wavURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioImportError.unsupportedFormat
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? AudioImportError.readFailed)
                case .cancelled:
                    continuation.resume(throwing: AudioImportError.readFailed)
                default:
                    continuation.resume(throwing: AudioImportError.readFailed)
                }
            }
        }

        return outputURL
    }
}

final class WhisperHTTPTranscriptionService {
    func transcribe(samples16kMono: [Float], language: String, endpointURL: URL) async throws -> String {
        let wavData = WAVEncoder.makeWAVData(samples: samples16kMono, sampleRate: 16_000)
        let boundary = "Boundary-\(UUID().uuidString)"
        let requestBody = makeMultipartBody(wavData: wavData, language: language, boundary: boundary)
        let audioSeconds = Double(samples16kMono.count) / 16_000.0
        let timeoutSeconds = max(120, min(1_800, (audioSeconds * 2.0) + 60))

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.serverError(
                statusCode: 408,
                message: "Client timeout after \(Int(timeoutSeconds))s. Try streaming mode or a shorter recording."
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw TranscriptionError.serverError(statusCode: http.statusCode, message: message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw TranscriptionError.invalidPayload
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMultipartBody(wavData: Data, language: String, boundary: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(wavData)
        body.append(lineBreak.data(using: .utf8)!)

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append("\(language)\(lineBreak)".data(using: .utf8)!)

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}

final class MLXHTTPTranscriptionService {
    func transcribe(samples16kMono: [Float], language: String, endpointURL: URL, modelID: String) async throws -> String {
        let wavData = WAVEncoder.makeWAVData(samples: samples16kMono, sampleRate: 16_000)
        let boundary = "Boundary-\(UUID().uuidString)"
        let audioSeconds = Double(samples16kMono.count) / 16_000.0
        let timeoutSeconds = max(60, min(900, (audioSeconds * 2.0) + 30))

        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(wavData)
        body.append(lineBreak.data(using: .utf8)!)

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append("\(modelID)\(lineBreak)".data(using: .utf8)!)

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append("\(language)\(lineBreak)".data(using: .utf8)!)

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "MLX server error"
            throw TranscriptionError.serverError(statusCode: http.statusCode, message: message)
        }

        return try parseText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseText(from data: Data) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String, !text.isEmpty {
                return text
            }
            if let accumulated = json["accumulated"] as? String, !accumulated.isEmpty {
                return accumulated
            }
        }

        guard let payload = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.invalidPayload
        }

        var textParts: [String] = []
        for line in payload.split(whereSeparator: \.isNewline) {
            guard
                let lineData = String(line).data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            if let accumulated = json["accumulated"] as? String, !accumulated.isEmpty {
                return accumulated
            }
            if let text = json["text"] as? String, !text.isEmpty {
                textParts.append(text)
            }
        }

        let merged = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if merged.isEmpty {
            throw TranscriptionError.invalidPayload
        }
        return merged
    }
}

final class AudioFileImportService {
    func importAudioFile(from fileURL: URL) throws -> AudioCaptureResult {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioImportError.readFailed
        }

        try audioFile.read(into: buffer)
        guard let floatChannelData = buffer.floatChannelData else {
            throw AudioImportError.unsupportedFormat
        }

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else {
            throw AudioImportError.readFailed
        }

        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            let channel = floatChannelData[0]
            for i in 0..<frames {
                mono[i] = channel[i]
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += floatChannelData[channel][frame]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        let downsampled = AudioCaptureService.resampleTo16k(samples: mono, nativeSampleRate: format.sampleRate)
        let duration = Double(downsampled.count) / 16_000.0
        return AudioCaptureResult(samples16kMono: downsampled, durationSeconds: duration, nativeSamplesCount: mono.count)
    }
}

final class VideoFileImportService {
    private let fileManager = FileManager.default

    func importVideoFile(from fileURL: URL) throws -> AudioCaptureResult {
        let extractedAudioURL = try extractAudioToTemporaryWAV(from: fileURL)
        defer { try? fileManager.removeItem(at: extractedAudioURL) }
        return try AudioFileImportService().importAudioFile(from: extractedAudioURL)
    }

    private func extractAudioToTemporaryWAV(from videoURL: URL) throws -> URL {
        let ffmpegURL = try resolveFFmpegURL()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-video-import-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-i", videoURL.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_f32le",
            outputURL.path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw VideoImportError.extractionFailed(message: error.localizedDescription)
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw VideoImportError.extractionFailed(message: stderrText.isEmpty ? "ffmpeg exited with code \(process.terminationStatus)" : stderrText)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw VideoImportError.outputMissing
        }

        return outputURL
    }

    private func resolveFFmpegURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CONTORA_FFMPEG_PATH"], fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }

        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffmpeg"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = Pipe()

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
        } catch {
            throw VideoImportError.ffmpegNotFound
        }

        guard whichProcess.terminationStatus == 0 else {
            throw VideoImportError.ffmpegNotFound
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else {
            throw VideoImportError.ffmpegNotFound
        }

        return URL(fileURLWithPath: path)
    }
}

final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var buffered16kScratchFile: PCMFloatScratchFileBuffer?
    private var nativeMonoSamples: [Float] = []
    private var nativeSampleRate: Double = 16_000
    private var isRunning = false
    private var startTime: Date?
    private var keepNativeBufferForStreaming = false
    private var nativeSamplesCount = 0

    func startCapture(keepNativeBufferForStreaming: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }

        buffered16kScratchFile?.discard()
        buffered16kScratchFile = try PCMFloatScratchFileBuffer(prefix: "contora-mic")
        nativeMonoSamples.removeAll(keepingCapacity: true)
        self.keepNativeBufferForStreaming = keepNativeBufferForStreaming
        nativeSamplesCount = 0

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        nativeSampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.appendNativeMonoSamples(buffer: buffer)
        }

        engine.prepare()
        try engine.start()

        startTime = Date()
        isRunning = true
    }

    func stopCapture() throws -> AudioCaptureResult {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else {
            throw AudioCaptureError.notRunning
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        let scratchFile = buffered16kScratchFile
        let nativeCount = nativeSamplesCount
        buffered16kScratchFile = nil
        nativeMonoSamples.removeAll(keepingCapacity: true)

        let buffered16k = try scratchFile?.finishReadingAllSamples() ?? []
        let duration = Double(buffered16k.count) / 16_000.0

        startTime = nil
        keepNativeBufferForStreaming = false
        nativeSamplesCount = 0
        return AudioCaptureResult(
            samples16kMono: buffered16k,
            durationSeconds: duration,
            nativeSamplesCount: nativeCount
        )
    }

    func elapsedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, let startTime else {
            return 0
        }
        return Date().timeIntervalSince(startTime)
    }

    func snapshotNativeMono(from startIndex: Int) -> (samples: [Float], nextIndex: Int, sampleRate: Double) {
        lock.lock()
        let safeStart = min(max(0, startIndex), nativeMonoSamples.count)
        let slice = Array(nativeMonoSamples[safeStart..<nativeMonoSamples.count])
        let nextIndex = nativeMonoSamples.count
        let sampleRate = nativeSampleRate
        lock.unlock()
        return (slice, nextIndex, sampleRate)
    }

    private func appendNativeMonoSamples(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else {
            return
        }

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if frames == 0 || channels == 0 {
            return
        }

        var mono = [Float](repeating: 0, count: frames)

        if channels == 1 {
            let channel = data[0]
            for i in 0..<frames {
                mono[i] = channel[i]
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += data[channel][frame]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        let downsampled = Self.resampleTo16k(samples: mono, nativeSampleRate: nativeSampleRate)

        lock.lock()
        nativeSamplesCount += mono.count
        do {
            try buffered16kScratchFile?.append(samples: downsampled)
        } catch {
            // Keep capture running even if scratch buffering fails for one chunk.
        }
        if keepNativeBufferForStreaming {
            nativeMonoSamples.append(contentsOf: mono)
        }
        lock.unlock()
    }

    static func resampleTo16k(samples: [Float], nativeSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }

        if abs(nativeSampleRate - 16_000.0) < 0.01 {
            return samples
        }

        let ratio = nativeSampleRate / 16_000.0
        let outCount = max(1, Int(Double(samples.count) / ratio))
        var output = [Float]()
        output.reserveCapacity(outCount)

        for outIndex in 0..<outCount {
            let srcPos = Double(outIndex) * ratio
            let srcIndex = Int(srcPos)

            if srcIndex + 1 < samples.count {
                let frac = Float(srcPos - Double(srcIndex))
                let value = samples[srcIndex] * (1 - frac) + samples[srcIndex + 1] * frac
                output.append(value)
            } else if srcIndex < samples.count {
                output.append(samples[srcIndex])
            }
        }

        return output
    }
}

@MainActor
final class PermissionState: ObservableObject {
    @Published var microphone: PermissionStatus = .unknown
    @Published var screenRecording: PermissionStatus = .unknown

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .notDetermined:
            microphone = .unknown
        default:
            microphone = .denied
        }

        screenRecording = SystemAudioCaptureService.hasPermission() ? .granted : .denied
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.microphone = granted ? .granted : .denied
            }
        }
    }

    func requestScreenRecording() {
        _ = SystemAudioCaptureService.requestPermission()
        refresh()
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var isRecording = false
    @Published var captureSourceMode: CaptureSourceMode = .mixed
    @Published var transcriptionEnabled = false
    @Published var streamingEnabled = false
    @Published var launchAtLogin = false
    @Published var chunkSeconds = 8
    @Published var recordingStoragePolicy: RecordingStoragePolicy = .wavOnly
    @Published var transcriptionLanguage = "ru"
    @Published var transcriptionBackend: TranscriptionBackend = .mlxOpenAIHTTP
    @Published var transcriptionEndpoint = "http://127.0.0.1:5500/transcribe"
    @Published var mlxTranscriptionEndpoint = "http://127.0.0.1:8000/v1/audio/transcriptions"
    @Published var mlxModelID = "mlx-community/whisper-large-v3-turbo-asr-fp16"

    @Published var recordingSeconds: Double = 0
    @Published var lastCaptureSamples: Int = 0
    @Published var isTranscribing = false
    @Published var isStreamingChunkTranscribing = false
    @Published var isFinalizingStop = false
    @Published var isStreamingLoopActive = false
    @Published var streamingChunksProcessed = 0
    @Published var transcriptionElapsedSeconds: Double = 0
    @Published var lastAudioDurationSeconds: Double = 0
    @Published var lastTranscriptionDurationSeconds: Double = 0
    @Published var lastRealtimeSpeedRatio: Double = 0

    @Published var postStopWaitSeconds: Double = 0
    @Published var lastPostStopWaitSeconds: Double = 0
    @Published var normalModePostStopBaselineSeconds: Double = 0
    @Published var lastStreamingSpeedupVsNormal: Double = 0
    @Published var lastSavedRecordingPath = ""
    @Published var lastSavedTranscriptPath = ""

    @Published var statusMessage = "Idle"
    @Published var lastTranscript = "No transcript yet."
    @Published var sharedServerConfigPath = ""
    @Published var sharedServerConfigStatus = "Not loaded"
    @Published var backendProbeStatus = "Not checked"
    @Published var sessions: [ContoraSession] = []
    @Published var selectedSessionID: String?
    @Published var sessionLibraryStatus = "Not loaded"
    @Published var sessionEditorTranscriptDraft = ""
    @Published var sessionEditorSegments: [EditableSessionSegment] = []
    @Published var sessionEditorStatus = "No session selected"
    @Published var storageStatus = "WAV only"
    @Published var diagnostics = RuntimeDiagnostics()
    @Published var sharedMLXToolkitActionStatus = "Idle"
    @Published var sharedModelCatalogEntries: [SharedModelCatalogEntry] = []

    let permissions = PermissionState()

    private let audioCapture = AudioCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()
    private let transcriber = WhisperHTTPTranscriptionService()
    private let mlxTranscriber = MLXHTTPTranscriptionService()
    private let audioFileImportService = AudioFileImportService()
    private let videoFileImportService = VideoFileImportService()
    private let audioCompressionService = AudioCompressionService()
    private let recordingArchive = RecordingArchiveService()
    private let sharedMLXToolkitService = SharedMLXServerToolkitService()
    private let sharedModelCatalogStore = SharedModelCatalogStore.shared
    private let sessionLibrary = SessionLibraryService()
    private var recordingTickerTask: Task<Void, Never>?
    private var transcriptionTickerTask: Task<Void, Never>?
    private var postStopTickerTask: Task<Void, Never>?
    private var streamingLoopTask: Task<Void, Never>?
    private var streamProcessedNativeIndex = 0
    private var streamingAccumulatedTranscript = ""
    private var postStopStartedAt: Date?
    private var currentRecordingFileURL: URL?
    private var currentSessionIdentity: RecordingArchiveService.SessionIdentity?

    private init() {
        sharedServerConfigPath = SharedTranscriptionServerConfigStore.shared.configFileURL().path
        loadSharedServerConfig()
        reloadSessions()
        refreshDiagnostics()
    }

    var selectedSession: ContoraSession? {
        guard let selectedSessionID else {
            return sessions.first
        }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    func loadSharedServerConfig() {
        do {
            let config = try SharedTranscriptionServerConfigStore.shared.loadOrCreate()
            transcriptionBackend = config.activeBackend
            transcriptionEndpoint = config.whisperTranscribeURL
            mlxTranscriptionEndpoint = config.mlxTranscribeURL
            mlxModelID = config.mlxModelID
            sharedServerConfigStatus = "Loaded (\(config.schemaVersion))"
        } catch {
            sharedServerConfigStatus = "Load failed: \(error.localizedDescription)"
        }
    }

    func saveSharedServerConfig() {
        let config = SharedTranscriptionServerConfig(
            schemaVersion: "1.0",
            activeBackend: transcriptionBackend,
            whisperTranscribeURL: transcriptionEndpoint,
            mlxTranscribeURL: mlxTranscriptionEndpoint,
            mlxModelID: mlxModelID,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try SharedTranscriptionServerConfigStore.shared.save(config)
            sharedServerConfigStatus = "Saved"
        } catch {
            sharedServerConfigStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    func probeSharedBackend() {
        backendProbeStatus = "Probing..."
        Task { [weak self] in
            guard let self else { return }
            let status = await SharedTranscriptionServerConfigStore.shared.probe(
                backend: transcriptionBackend,
                whisperURL: transcriptionEndpoint,
                mlxURL: mlxTranscriptionEndpoint
            )
            await MainActor.run {
                self.backendProbeStatus = status
                self.diagnostics.activeBackend = "\(self.transcriptionBackend.rawValue) | \(status)"
            }
        }
    }

    func refreshDiagnostics() {
        diagnostics.sharedRuntimeRoot = SharedRuntimePaths.sharedRuntimeRoot().path
        diagnostics.whisperExecutablePath = SharedRuntimePaths.whisperExecutable().path
        diagnostics.modelsDirectoryPath = SharedRuntimePaths.modelsDirectory().path
        diagnostics.sharedConfigPath = SharedTranscriptionServerConfigStore.shared.configFileURL().path
        diagnostics.sharedModelCatalogPath = sharedModelCatalogStore.catalogURL().path
        diagnostics.activeBackend = transcriptionBackend.rawValue

        if let toolkit = sharedMLXToolkitService.discoverToolkit() {
            diagnostics.sharedMLXToolkitRoot = toolkit.baseURL.path
            diagnostics.sharedMLXLogPath = toolkit.logFileURL.path
            diagnostics.sharedMLXToolkitStatus = "Present"
        } else {
            diagnostics.sharedMLXToolkitRoot = ""
            diagnostics.sharedMLXLogPath = ""
            diagnostics.sharedMLXToolkitStatus = "Missing"
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        diagnostics.sharedRuntimeRootStatus = fileManager.fileExists(atPath: diagnostics.sharedRuntimeRoot, isDirectory: &isDirectory) && isDirectory.boolValue ? "Present" : "Missing"
        diagnostics.whisperExecutableStatus = fileManager.isExecutableFile(atPath: diagnostics.whisperExecutablePath) ? "Executable" : "Missing"
        isDirectory = false
        diagnostics.modelsDirectoryStatus = fileManager.fileExists(atPath: diagnostics.modelsDirectoryPath, isDirectory: &isDirectory) && isDirectory.boolValue ? "Present" : "Missing"
        diagnostics.sharedConfigStatus = fileManager.fileExists(atPath: diagnostics.sharedConfigPath) ? "Present" : "Missing"
        diagnostics.sharedModelCatalogStatus = fileManager.fileExists(atPath: diagnostics.sharedModelCatalogPath) ? "Present" : "Missing"

        refreshFFmpegDiagnostics()
        refreshSharedModelCatalog()
        probeSharedBackend()
    }

    func refreshSharedModelCatalog() {
        do {
            let catalog = try sharedModelCatalogStore.refresh()
            sharedModelCatalogEntries = catalog.entries
            diagnostics.sharedModelCatalogStatus = "Present"
            let grouped = Dictionary(grouping: catalog.entries, by: { $0.provider.rawValue })
            diagnostics.sharedModelCatalogSummary = grouped
                .keys
                .sorted()
                .map { "\($0): \(grouped[$0]?.count ?? 0)" }
                .joined(separator: " | ")
        } catch {
            sharedModelCatalogEntries = []
            diagnostics.sharedModelCatalogStatus = "Load failed"
            diagnostics.sharedModelCatalogSummary = error.localizedDescription
        }
    }

    func startSharedMLXToolkitServer() {
        guard let toolkit = sharedMLXToolkitService.discoverToolkit() else {
            sharedMLXToolkitActionStatus = "Shared MLX toolkit not found"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try self.sharedMLXToolkitService.runScript(at: toolkit.startScriptURL)
                self.sharedMLXToolkitActionStatus = output.isEmpty ? "Shared MLX server started" : output
                self.refreshDiagnostics()
            } catch {
                self.sharedMLXToolkitActionStatus = error.localizedDescription
            }
        }
    }

    func stopSharedMLXToolkitServer() {
        guard let toolkit = sharedMLXToolkitService.discoverToolkit() else {
            sharedMLXToolkitActionStatus = "Shared MLX toolkit not found"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try self.sharedMLXToolkitService.runScript(at: toolkit.stopScriptURL)
                self.sharedMLXToolkitActionStatus = output.isEmpty ? "Shared MLX server stopped" : output
                self.refreshDiagnostics()
            } catch {
                self.sharedMLXToolkitActionStatus = error.localizedDescription
            }
        }
    }

    func checkSharedMLXToolkitServer() {
        guard let toolkit = sharedMLXToolkitService.discoverToolkit() else {
            sharedMLXToolkitActionStatus = "Shared MLX toolkit not found"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try self.sharedMLXToolkitService.runScript(at: toolkit.checkScriptURL)
                self.sharedMLXToolkitActionStatus = output.isEmpty ? "Shared MLX check completed" : output
                self.refreshDiagnostics()
            } catch {
                self.sharedMLXToolkitActionStatus = error.localizedDescription
            }
        }
    }

    func openSharedMLXLog() {
        guard let toolkit = sharedMLXToolkitService.discoverToolkit() else {
            sharedMLXToolkitActionStatus = "Shared MLX toolkit not found"
            return
        }
        openURL(toolkit.logFileURL)
    }

    private func refreshFFmpegDiagnostics() {
        let candidatePaths = [
            ProcessInfo.processInfo.environment["CONTORA_FFMPEG_PATH"],
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let fileManager = FileManager.default
        let ffmpegPath = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) ?? resolveFFmpegViaWhich()

        guard let ffmpegPath else {
            diagnostics.ffmpegStatus = "Missing"
            diagnostics.ffmpegPath = ""
            diagnostics.ffmpegVersion = ""
            return
        }

        diagnostics.ffmpegPath = ffmpegPath
        diagnostics.ffmpegStatus = "Available"
        diagnostics.ffmpegVersion = ffmpegVersion(at: ffmpegPath)
    }

    private func resolveFFmpegViaWhich() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private func ffmpegVersion(at path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Unavailable"
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: .newlines).first ?? "Unknown"
    }

    func reloadSessions() {
        do {
            sessions = try sessionLibrary.loadSessions()
            if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = sessions.first?.id
            }
            loadEditorForSelectedSession()
            sessionLibraryStatus = "Loaded \(sessions.count) session(s)"
        } catch {
            sessions = []
            selectedSessionID = nil
            sessionEditorTranscriptDraft = ""
            sessionEditorSegments = []
            sessionLibraryStatus = "Load failed: \(error.localizedDescription)"
        }
    }

    func selectSession(_ sessionID: String?) {
        selectedSessionID = sessionID
        loadEditorForSelectedSession()
    }

    func revealSession(_ session: ContoraSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.recordingURL])
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func saveSelectedSessionEdits() {
        guard let session = selectedSession else {
            sessionEditorStatus = "No session selected"
            return
        }

        do {
            let transcriptText: String
            let speakers: [ContoraSession.Speaker]
            let segments: [ContoraSession.Segment]

            if !sessionEditorSegments.isEmpty {
                transcriptText = sessionEditorSegments.map { segment in
                    "[\(formatTranscriptTime(segment.startSeconds)) --> \(formatTranscriptTime(segment.endSeconds))] [\(segment.speakerName)]: \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                }.joined(separator: "\n")

                let speakerMap = Dictionary(uniqueKeysWithValues: sessionEditorSegments.map { ($0.speakerID, $0.speakerName) })
                speakers = speakerMap.keys.sorted().map { key in
                    ContoraSession.Speaker(id: key, displayName: speakerMap[key] ?? key)
                }
                segments = sessionEditorSegments.map {
                    ContoraSession.Segment(
                        id: $0.id,
                        startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds,
                        speakerID: $0.speakerID,
                        text: $0.text
                    )
                }
            } else {
                transcriptText = sessionEditorTranscriptDraft
                let parsed = TranscriptSegmentParser().parseSpeakersAndSegments(from: transcriptText)
                speakers = parsed.speakers
                segments = parsed.segments
            }

            let txtURL = try recordingArchive.saveTranscriptText(for: session.recordingURL, transcriptText: transcriptText)
            let jsonURL = try recordingArchive.updateTranscriptJSONPreservingMetadata(for: session.recordingURL, transcriptText: transcriptText)
            let createdAt = ISO8601DateFormatter().date(from: session.metadata.createdAt ?? "") ?? session.createdAt
            let siblingM4A = existingSiblingM4A(for: session.recordingURL)
            _ = try recordingArchive.saveSessionManifest(
                sessionID: .init(sessionID: session.id, title: session.title, createdAt: createdAt),
                recordingFileURL: session.recordingURL,
                captureSourceMode: session.metadata.mode ?? "Unknown",
                audioSeconds: session.metadata.audioSeconds ?? 0,
                recordingM4AURL: siblingM4A,
                transcriptTXT: txtURL,
                transcriptJSON: jsonURL,
                transcription: .init(
                    status: session.metadata.success == false ? "failed" : "completed",
                    backend: nil,
                    endpoint: session.metadata.endpoint,
                    language: session.metadata.language,
                    mode: session.metadata.mode,
                    durationSeconds: nil,
                    errorMessage: session.metadata.errorMessage,
                    speakers: speakers.map { .init(id: $0.id, displayName: $0.displayName) },
                    segments: segments.map {
                        .init(
                            id: $0.id,
                            startSeconds: $0.startSeconds,
                            endSeconds: $0.endSeconds,
                            speakerID: $0.speakerID,
                            text: $0.text
                        )
                    }
                )
            )
            sessionEditorStatus = "Saved"
            reloadSessions()
        } catch {
            sessionEditorStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    func updateSpeakerName(speakerID: String, newName: String) {
        for index in sessionEditorSegments.indices where sessionEditorSegments[index].speakerID == speakerID {
            sessionEditorSegments[index].speakerName = newName
        }
    }

    private func loadEditorForSelectedSession() {
        guard let session = selectedSession else {
            sessionEditorTranscriptDraft = ""
            sessionEditorSegments = []
            sessionEditorStatus = "No session selected"
            return
        }

        if let transcriptURL = session.transcriptURL,
           let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            sessionEditorTranscriptDraft = text
        } else {
            sessionEditorTranscriptDraft = ""
        }

        let speakerNameMap = Dictionary(uniqueKeysWithValues: session.speakers.map { ($0.id, $0.displayName) })
        sessionEditorSegments = session.segments.map {
            EditableSessionSegment(
                id: $0.id,
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds,
                speakerID: $0.speakerID,
                speakerName: speakerNameMap[$0.speakerID] ?? $0.speakerID,
                text: $0.text
            )
        }
        sessionEditorStatus = "Loaded"
    }

    private func formatTranscriptTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let wholeSeconds = Int(seconds) % 60
        let milliseconds = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, wholeSeconds, milliseconds)
    }

    private func applyStoragePolicy(to wavURL: URL) async -> URL {
        switch recordingStoragePolicy {
        case .wavOnly:
            storageStatus = "WAV only"
            return wavURL
        case .wavPlusM4A:
            do {
                _ = try await audioCompressionService.compressToM4A(wavURL: wavURL)
                storageStatus = "Saved WAV + M4A"
                return wavURL
            } catch {
                storageStatus = "M4A compression failed, kept WAV"
                return wavURL
            }
        case .m4aOnly:
            do {
                let m4aURL = try await audioCompressionService.compressToM4A(wavURL: wavURL)
                try? FileManager.default.removeItem(at: wavURL)
                storageStatus = "Saved M4A only"
                return m4aURL
            } catch {
                storageStatus = "M4A compression failed, kept WAV"
                return wavURL
            }
        }
    }

    private func existingSiblingM4A(for recordingURL: URL) -> URL? {
        let sibling = recordingArchive.siblingCompressedURL(for: recordingURL)
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return recordingURL.pathExtension.lowercased() == "m4a" ? recordingURL : nil
    }

    func importAudioFile(from fileURL: URL) {
        guard !isRecording, !isTranscribing, !isFinalizingStop else {
            statusMessage = "Finish the current operation before importing audio"
            return
        }

        Task { [weak self] in
            await self?.importAudioFileFlow(from: fileURL)
        }
    }

    func importVideoFile(from fileURL: URL) {
        guard !isRecording, !isTranscribing, !isFinalizingStop else {
            statusMessage = "Finish the current operation before importing video"
            return
        }

        Task { [weak self] in
            await self?.importVideoFileFlow(from: fileURL)
        }
    }

    func toggleRecording() {
        if isRecording {
            // Stop must always work, even while streaming chunk is currently transcribing.
            if isFinalizingStop {
                return
            }
            Task { [weak self] in
                await self?.stopRecordingFlow()
            }
        } else {
            if isTranscribing || isStreamingChunkTranscribing || isFinalizingStop {
                return
            }
            Task { [weak self] in
                await self?.startRecordingFlow()
            }
        }
    }

    private func startRecordingFlow() async {
        do {
            if requiresMicrophoneCapture() {
                try audioCapture.startCapture(keepNativeBufferForStreaming: streamingEnabled && transcriptionEnabled && captureSourceMode != .systemAudio)
            }
            if requiresSystemAudioCapture() {
                try await systemAudioCapture.startCapture()
            }

            isRecording = true
            isTranscribing = false
            isStreamingChunkTranscribing = false
            isStreamingLoopActive = false
            recordingSeconds = 0
            transcriptionElapsedSeconds = 0
            postStopWaitSeconds = 0
            lastPostStopWaitSeconds = 0
            lastStreamingSpeedupVsNormal = 0
            lastCaptureSamples = 0
            streamingChunksProcessed = 0
            lastRealtimeSpeedRatio = 0
            streamProcessedNativeIndex = 0
            streamingAccumulatedTranscript = ""
            currentRecordingFileURL = nil
            currentSessionIdentity = nil
            isFinalizingStop = false
            statusMessage = "Recording from \(captureSourceMode.rawValue)"
            lastTranscript = "Recording in progress..."
            startRecordingTicker()
            if streamingEnabled && transcriptionEnabled && captureSourceMode != .systemAudio {
                startStreamingLoop()
            }
        } catch {
            if requiresMicrophoneCapture() {
                _ = try? audioCapture.stopCapture()
            }
            if requiresSystemAudioCapture() {
                _ = try? await systemAudioCapture.stopCapture()
            }
            statusMessage = "Failed to start recording"
            lastTranscript = "Audio start error: \(error.localizedDescription)"
        }
    }

    private func importAudioFileFlow(from fileURL: URL) async {
        isFinalizingStop = true
        statusMessage = "Importing audio..."
        lastTranscript = "Preparing imported audio..."
        postStopStartedAt = Date()
        startPostStopTicker()

        do {
            let result = try audioFileImportService.importAudioFile(from: fileURL)
            lastAudioDurationSeconds = result.durationSeconds
            lastCaptureSamples = result.samples16kMono.count
            let archive = try recordingArchive.saveRecording(samples16kMono: result.samples16kMono)
            let storedRecordingURL = await applyStoragePolicy(to: archive.1)
            lastSavedRecordingPath = storedRecordingURL.path
            currentRecordingFileURL = storedRecordingURL
            currentSessionIdentity = archive.0
            _ = try? recordingArchive.saveSessionManifest(
                sessionID: archive.0,
                recordingFileURL: storedRecordingURL,
                captureSourceMode: "Imported Audio",
                audioSeconds: result.durationSeconds,
                recordingM4AURL: existingSiblingM4A(for: storedRecordingURL)
            )
            reloadSessions()

            if transcriptionEnabled {
                statusMessage = "Imported audio ready, transcribing..."
                lastTranscript = "Imported \(fileURL.lastPathComponent), \(formatSeconds(result.durationSeconds))."
                runTranscription(samples16k: result.samples16kMono, audioDurationSeconds: result.durationSeconds, mode: .normal)
            } else {
                completePostStopMeasurement(mode: .normal)
                statusMessage = "Imported audio saved"
                lastTranscript = "Imported \(fileURL.lastPathComponent) as session WAV."
                finishProcessingState()
            }
        } catch {
            finishProcessingState()
            statusMessage = "Import failed"
            lastTranscript = "Audio import error: \(error.localizedDescription)"
        }
    }

    private func importVideoFileFlow(from fileURL: URL) async {
        isFinalizingStop = true
        statusMessage = "Importing video..."
        lastTranscript = "Extracting audio from video..."
        postStopStartedAt = Date()
        startPostStopTicker()

        do {
            let result = try videoFileImportService.importVideoFile(from: fileURL)
            lastAudioDurationSeconds = result.durationSeconds
            lastCaptureSamples = result.samples16kMono.count
            let archive = try recordingArchive.saveRecording(samples16kMono: result.samples16kMono)
            let storedRecordingURL = await applyStoragePolicy(to: archive.1)
            lastSavedRecordingPath = storedRecordingURL.path
            currentRecordingFileURL = storedRecordingURL
            currentSessionIdentity = archive.0
            _ = try? recordingArchive.saveSessionManifest(
                sessionID: archive.0,
                recordingFileURL: storedRecordingURL,
                captureSourceMode: "Imported Video",
                audioSeconds: result.durationSeconds,
                recordingM4AURL: existingSiblingM4A(for: storedRecordingURL)
            )
            reloadSessions()

            if transcriptionEnabled {
                statusMessage = "Video audio ready, transcribing..."
                lastTranscript = "Imported \(fileURL.lastPathComponent), \(formatSeconds(result.durationSeconds))."
                runTranscription(samples16k: result.samples16kMono, audioDurationSeconds: result.durationSeconds, mode: .normal)
            } else {
                completePostStopMeasurement(mode: .normal)
                statusMessage = "Video audio saved"
                lastTranscript = "Imported \(fileURL.lastPathComponent) as session WAV."
                finishProcessingState()
            }
        } catch {
            finishProcessingState()
            statusMessage = "Video import failed"
            lastTranscript = "Video import error: \(error.localizedDescription)"
        }
    }

    private func stopRecordingFlow() async {
        recordingTickerTask?.cancel()
        recordingTickerTask = nil
        isRecording = false
        isFinalizingStop = true
        statusMessage = "Stopping recording..."
        lastTranscript = "Finalizing recording..."
        postStopStartedAt = Date()
        startPostStopTicker()

        do {
            if streamingEnabled && transcriptionEnabled {
                if let task = streamingLoopTask {
                    task.cancel()
                }
                streamingLoopTask = nil
                isStreamingLoopActive = false
                statusMessage = "Finalizing streaming transcription..."
                let waitStartedAt = Date()
                while isStreamingChunkTranscribing {
                    if Date().timeIntervalSince(waitStartedAt) > 15 {
                        // Prevent indefinite wait on edge-case state desync.
                        isStreamingChunkTranscribing = false
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await transcribeNextStreamingChunk(isFinal: true)
            }

            let micResult = try stopMicrophoneCaptureIfNeeded()
            let systemResult = try await stopSystemCaptureIfNeeded()
            let result = mergeCaptureResults(microphone: micResult, system: systemResult)

            guard !result.samples16kMono.isEmpty else {
                finishProcessingState()
                statusMessage = "No audio captured"
                lastTranscript = "Recording completed but no audio samples were captured."
                return
            }

            recordingSeconds = result.durationSeconds
            lastAudioDurationSeconds = result.durationSeconds
            lastCaptureSamples = result.samples16kMono.count
            do {
                let archive = try recordingArchive.saveRecording(samples16kMono: result.samples16kMono)
                let storedRecordingURL = await applyStoragePolicy(to: archive.1)
                lastSavedRecordingPath = storedRecordingURL.path
                currentRecordingFileURL = storedRecordingURL
                currentSessionIdentity = archive.0
                _ = try? recordingArchive.saveSessionManifest(
                    sessionID: archive.0,
                    recordingFileURL: storedRecordingURL,
                    captureSourceMode: captureSourceMode.rawValue,
                    audioSeconds: result.durationSeconds,
                    recordingM4AURL: existingSiblingM4A(for: storedRecordingURL)
                )
                reloadSessions()
            } catch {
                statusMessage = "Recording saved in memory only (archive error)."
            }

            if transcriptionEnabled {
                if streamingEnabled {
                    let trimmed = streamingAccumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        statusMessage = "Streaming returned no text, running full transcription fallback..."
                        lastTranscript = "Streaming fallback: running full transcription..."
                        runTranscription(samples16k: result.samples16kMono, audioDurationSeconds: result.durationSeconds, mode: .streamingFallback)
                    } else {
                        lastTranscriptionDurationSeconds = Date().timeIntervalSince(postStopStartedAt ?? Date())
                        lastRealtimeSpeedRatio = lastTranscriptionDurationSeconds > 0 ? result.durationSeconds / lastTranscriptionDurationSeconds : 0
                        completePostStopMeasurement(mode: .streaming)
                        statusMessage = "Streaming transcription complete (wait \(formatSeconds(lastPostStopWaitSeconds)))"
                        lastTranscript = trimmed
                        persistTranscript(text: trimmed, mode: .streaming, success: true, errorMessage: nil)
                        finishProcessingState()
                    }
                } else {
                    statusMessage = "Capture complete, transcribing..."
                    lastTranscript = "Captured \(Int(result.durationSeconds * 10) / 10)s, \(result.samples16kMono.count) samples (16k mono)."
                    runTranscription(samples16k: result.samples16kMono, audioDurationSeconds: result.durationSeconds, mode: .normal)
                }
            } else {
                completePostStopMeasurement(mode: .normal)
                statusMessage = "Recording saved"
                lastTranscript = "Saved \(formatSeconds(result.durationSeconds)) (\(result.samples16kMono.count) samples)."
                finishProcessingState()
            }
        } catch {
            isRecording = false
            finishProcessingState()
            statusMessage = "Failed to stop recording"
            lastTranscript = "Audio stop error: \(error.localizedDescription)"
        }
    }

    private func requiresMicrophoneCapture() -> Bool {
        captureSourceMode == .microphone || captureSourceMode == .mixed
    }

    private func requiresSystemAudioCapture() -> Bool {
        captureSourceMode == .systemAudio || captureSourceMode == .mixed
    }

    private func stopMicrophoneCaptureIfNeeded() throws -> AudioCaptureResult? {
        guard requiresMicrophoneCapture() else {
            return nil
        }
        return try audioCapture.stopCapture()
    }

    private func stopSystemCaptureIfNeeded() async throws -> AudioCaptureResult? {
        guard requiresSystemAudioCapture() else {
            return nil
        }
        return try await systemAudioCapture.stopCapture()
    }

    private func mergeCaptureResults(microphone: AudioCaptureResult?, system: AudioCaptureResult?) -> AudioCaptureResult {
        switch (microphone, system) {
        case let (mic?, nil):
            return mic
        case let (nil, sys?):
            return sys
        case let (mic?, sys?):
            let mixed = mix16kMono(mic.samples16kMono, sys.samples16kMono)
            let duration = Double(mixed.count) / 16_000.0
            return AudioCaptureResult(
                samples16kMono: mixed,
                durationSeconds: duration,
                nativeSamplesCount: mic.nativeSamplesCount + sys.nativeSamplesCount
            )
        case (nil, nil):
            return AudioCaptureResult(samples16kMono: [], durationSeconds: 0, nativeSamplesCount: 0)
        }
    }

    private func activeTranscriptionEndpointString() -> String {
        switch transcriptionBackend {
        case .whisperHTTP:
            return transcriptionEndpoint
        case .mlxOpenAIHTTP:
            return mlxTranscriptionEndpoint
        }
    }

    private func transcribeWithSelectedBackend(samples16k: [Float]) async throws -> String {
        switch transcriptionBackend {
        case .whisperHTTP:
            guard let endpointURL = URL(string: transcriptionEndpoint) else {
                throw TranscriptionError.serverError(statusCode: 400, message: "Invalid Whisper endpoint URL")
            }
            return try await transcriber.transcribe(
                samples16kMono: samples16k,
                language: transcriptionLanguage,
                endpointURL: endpointURL
            )

        case .mlxOpenAIHTTP:
            guard let endpointURL = URL(string: mlxTranscriptionEndpoint) else {
                throw TranscriptionError.serverError(statusCode: 400, message: "Invalid MLX endpoint URL")
            }
            return try await mlxTranscriber.transcribe(
                samples16kMono: samples16k,
                language: transcriptionLanguage,
                endpointURL: endpointURL,
                modelID: mlxModelID
            )
        }
    }

    private func mix16kMono(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
        let count = max(lhs.count, rhs.count)
        if count == 0 {
            return []
        }

        var output = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            output[i] = max(-1.0, min(1.0, (l + r) * 0.5))
        }
        return output
    }

    private enum TranscriptionMode {
        case normal
        case streaming
        case streamingFallback
    }

    private func runTranscription(samples16k: [Float], audioDurationSeconds: Double, mode: TranscriptionMode) {
        isTranscribing = true
        isStreamingChunkTranscribing = false
        transcriptionElapsedSeconds = 0

        let transcribeStartedAt = Date()
        startTranscriptionTicker(from: transcribeStartedAt)

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let text = try await self.transcribeWithSelectedBackend(samples16k: samples16k)
                await MainActor.run {
                    self.transcriptionTickerTask?.cancel()
                    self.transcriptionTickerTask = nil
                    self.isTranscribing = false
                    self.lastTranscriptionDurationSeconds = Date().timeIntervalSince(transcribeStartedAt)
                    if self.lastTranscriptionDurationSeconds > 0 {
                        self.lastRealtimeSpeedRatio = audioDurationSeconds / self.lastTranscriptionDurationSeconds
                    }
                    self.completePostStopMeasurement(mode: mode)
                    self.statusMessage = "Transcription complete (wait \(self.formatSeconds(self.lastPostStopWaitSeconds)))"
                    self.lastTranscript = text.isEmpty ? "[Empty transcription]" : text
                    self.persistTranscript(text: self.lastTranscript, mode: mode, success: true, errorMessage: nil)
                    self.finishProcessingState()
                }
            } catch {
                await MainActor.run {
                    self.transcriptionTickerTask?.cancel()
                    self.transcriptionTickerTask = nil
                    self.isTranscribing = false
                    self.lastTranscriptionDurationSeconds = Date().timeIntervalSince(transcribeStartedAt)
                    if self.lastTranscriptionDurationSeconds > 0 {
                        self.lastRealtimeSpeedRatio = audioDurationSeconds / self.lastTranscriptionDurationSeconds
                    }
                    self.completePostStopMeasurement(mode: mode)
                    self.statusMessage = "Transcription failed"
                    self.lastTranscript = "Transcription error (\(self.transcriptionEndpoint)): \(error.localizedDescription)"
                    self.persistTranscript(text: self.lastTranscript, mode: mode, success: false, errorMessage: error.localizedDescription)
                    self.finishProcessingState()
                }
            }
        }
    }

    private func persistTranscript(text: String, mode: TranscriptionMode, success: Bool, errorMessage: String?) {
        guard let recordingURL = currentRecordingFileURL, let sessionIdentity = currentSessionIdentity else {
            return
        }
        do {
            let modeString: String
            switch mode {
            case .normal:
                modeString = "normal"
            case .streaming:
                modeString = "streaming"
            case .streamingFallback:
                modeString = "streaming_fallback"
            }
            let parsed = TranscriptSegmentParser().parseSpeakersAndSegments(from: text)
            let txtURL = try recordingArchive.saveTranscriptText(for: recordingURL, transcriptText: text)
            let jsonURL = try recordingArchive.saveTranscriptJSON(
                for: recordingURL,
                transcriptText: text,
                mode: modeString,
                language: transcriptionLanguage,
                endpoint: activeTranscriptionEndpointString(),
                audioSeconds: lastAudioDurationSeconds,
                postStopWaitSeconds: lastPostStopWaitSeconds,
                transcriptionSeconds: lastTranscriptionDurationSeconds > 0 ? lastTranscriptionDurationSeconds : nil,
                success: success,
                errorMessage: errorMessage
            )
            let transcriptionStatus = success ? "completed" : "failed"
            let siblingM4A = existingSiblingM4A(for: recordingURL)
            _ = try? recordingArchive.saveSessionManifest(
                sessionID: sessionIdentity,
                recordingFileURL: recordingURL,
                captureSourceMode: captureSourceMode.rawValue,
                audioSeconds: lastAudioDurationSeconds,
                recordingM4AURL: siblingM4A,
                transcriptTXT: txtURL,
                transcriptJSON: jsonURL,
                transcription: .init(
                    status: transcriptionStatus,
                    backend: transcriptionBackend.rawValue,
                    endpoint: activeTranscriptionEndpointString(),
                    language: transcriptionLanguage,
                    mode: modeString,
                    durationSeconds: lastTranscriptionDurationSeconds > 0 ? lastTranscriptionDurationSeconds : nil,
                    errorMessage: errorMessage,
                    speakers: parsed.speakers.map { .init(id: $0.id, displayName: $0.displayName) },
                    segments: parsed.segments.map {
                        .init(
                            id: $0.id,
                            startSeconds: $0.startSeconds,
                            endSeconds: $0.endSeconds,
                            speakerID: $0.speakerID,
                            text: $0.text
                        )
                    }
                )
            )
            lastSavedTranscriptPath = txtURL.path
            reloadSessions()
        } catch {
            // Keep the main flow stable even if transcript archive write fails.
        }
    }

    private func finishProcessingState() {
        isFinalizingStop = false
        isTranscribing = false
        isStreamingChunkTranscribing = false
        isStreamingLoopActive = false
        stopPostStopTicker()
        currentSessionIdentity = nil
    }

    private func completePostStopMeasurement(mode: TranscriptionMode) {
        guard let started = postStopStartedAt else {
            return
        }

        let waited = Date().timeIntervalSince(started)
        lastPostStopWaitSeconds = waited
        postStopWaitSeconds = waited

        switch mode {
        case .normal:
            if normalModePostStopBaselineSeconds == 0 {
                normalModePostStopBaselineSeconds = waited
            } else {
                normalModePostStopBaselineSeconds = (normalModePostStopBaselineSeconds + waited) / 2.0
            }
            lastStreamingSpeedupVsNormal = 0
        case .streaming:
            if normalModePostStopBaselineSeconds > 0, waited > 0 {
                lastStreamingSpeedupVsNormal = normalModePostStopBaselineSeconds / waited
            }
        case .streamingFallback:
            if normalModePostStopBaselineSeconds > 0, waited > 0 {
                lastStreamingSpeedupVsNormal = normalModePostStopBaselineSeconds / waited
            }
        }

        stopPostStopTicker()
    }

    private func startStreamingLoop() {
        streamingLoopTask?.cancel()
        isStreamingLoopActive = true
        streamingLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !streamingEnabled || !isRecording {
                    break
                }

                let chunkTarget = Double(max(chunkSeconds, 1))
                if unprocessedNativeDurationSeconds() >= chunkTarget {
                    await transcribeNextStreamingChunk(isFinal: false)
                    continue
                }

                try? await Task.sleep(for: .milliseconds(350))
            }
            await MainActor.run {
                self.isStreamingLoopActive = false
            }
        }
    }

    private func unprocessedNativeDurationSeconds() -> Double {
        let snapshot = audioCapture.snapshotNativeMono(from: streamProcessedNativeIndex)
        guard snapshot.sampleRate > 0 else {
            return 0
        }
        return Double(snapshot.samples.count) / snapshot.sampleRate
    }

    private func transcribeNextStreamingChunk(isFinal: Bool) async {
        if isStreamingChunkTranscribing {
            return
        }

        let snapshot = audioCapture.snapshotNativeMono(from: streamProcessedNativeIndex)
        streamProcessedNativeIndex = snapshot.nextIndex

        if snapshot.samples.isEmpty {
            return
        }

        let chunk16k = AudioCaptureService.resampleTo16k(samples: snapshot.samples, nativeSampleRate: snapshot.sampleRate)
        let audioSeconds = Double(chunk16k.count) / 16_000.0
        if !isFinal && audioSeconds < 0.2 {
            return
        }

        isStreamingChunkTranscribing = true
        statusMessage = "Streaming chunk transcription..."

        do {
            let text = try await transcribeWithSelectedBackend(samples16k: chunk16k)

            streamingChunksProcessed += 1

            if !text.isEmpty {
                if !streamingAccumulatedTranscript.isEmpty {
                    streamingAccumulatedTranscript.append(" ")
                }
                streamingAccumulatedTranscript.append(text)
                lastTranscript = streamingAccumulatedTranscript
            }

            statusMessage = "Streaming active (\(streamingChunksProcessed) chunks, ~\(formatSeconds(audioSeconds))/chunk)"
        } catch {
            statusMessage = "Streaming chunk failed: \(error.localizedDescription)"
        }

        isStreamingChunkTranscribing = false
    }

    private func startRecordingTicker() {
        recordingTickerTask?.cancel()
        recordingTickerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let micElapsed = self.requiresMicrophoneCapture() ? self.audioCapture.elapsedSeconds() : 0
                let systemElapsed = self.requiresSystemAudioCapture() ? self.systemAudioCapture.elapsedSeconds() : 0
                self.recordingSeconds = max(micElapsed, systemElapsed)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func startTranscriptionTicker(from startDate: Date) {
        transcriptionTickerTask?.cancel()
        transcriptionTickerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.transcriptionElapsedSeconds = Date().timeIntervalSince(startDate)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func startPostStopTicker() {
        postStopTickerTask?.cancel()
        guard let started = postStopStartedAt else {
            return
        }

        postStopTickerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.postStopWaitSeconds = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopPostStopTicker() {
        postStopTickerTask?.cancel()
        postStopTickerTask = nil
        postStopStartedAt = nil
    }

    private func formatRatio(_ value: Double) -> String {
        let clamped = max(0, value)
        let rounded = Int(clamped * 100) / 100
        return "\(rounded)x realtime"
    }

    private func formatSeconds(_ value: Double) -> String {
        let rounded = Int(max(0, value) * 10) / 10
        return "\(rounded)s"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var recordItem: NSMenuItem?
    private var streamingItem: NSMenuItem?
    private var sourceMicItem: NSMenuItem?
    private var sourceSystemItem: NSMenuItem?
    private var sourceMixedItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var chunk3Item: NSMenuItem?
    private var chunk8Item: NSMenuItem?
    private var chunk15Item: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    private var didConfigureTickerWindow = false
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        bindState()
        model.permissions.refresh()
        DispatchQueue.main.async { [weak self] in
            self?.configureTickerWindowIfNeeded()
            self?.updateTickerWindowVisibility()
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusIconImage(isRecording: false, isProcessing: false)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone

        let menu = NSMenu()

        let summary = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        let openItem = NSMenuItem(title: "Open Contora Panel", action: #selector(openDashboard), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let openRecordingsItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: "")
        openRecordingsItem.target = self
        menu.addItem(openRecordingsItem)

        let importAudioItem = NSMenuItem(title: "Import Audio File...", action: #selector(importAudioFile), keyEquivalent: "")
        importAudioItem.target = self
        menu.addItem(importAudioItem)

        let importVideoItem = NSMenuItem(title: "Import Video File...", action: #selector(importVideoFile), keyEquivalent: "")
        importVideoItem.target = self
        menu.addItem(importVideoItem)

        menu.addItem(.separator())

        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        let sourceMenu = NSMenu()
        let sourceMic = NSMenuItem(title: "Microphone", action: #selector(setSourceMicrophone), keyEquivalent: "")
        sourceMic.target = self
        sourceMenu.addItem(sourceMic)
        let sourceSystem = NSMenuItem(title: "System Audio", action: #selector(setSourceSystemAudio), keyEquivalent: "")
        sourceSystem.target = self
        sourceMenu.addItem(sourceSystem)
        let sourceMixed = NSMenuItem(title: "System + Microphone", action: #selector(setSourceMixed), keyEquivalent: "")
        sourceMixed.target = self
        sourceMenu.addItem(sourceMixed)
        let sourceRoot = NSMenuItem(title: "Capture Source", action: nil, keyEquivalent: "")
        menu.setSubmenu(sourceMenu, for: sourceRoot)
        menu.addItem(sourceRoot)

        let streaming = NSMenuItem(title: "Streaming Mode", action: #selector(toggleStreaming), keyEquivalent: "")
        streaming.target = self

        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Contora", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusSummaryItem = summary
        self.recordItem = record
        self.streamingItem = streaming
        self.sourceMicItem = sourceMic
        self.sourceSystemItem = sourceSystem
        self.sourceMixedItem = sourceMixed
        self.launchAtLoginItem = launchAtLogin
        self.statusItem = item
        self.statusItem?.menu = menu

        refreshMenuState()
    }

    private func bindState() {
        model.$isRecording
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$streamingEnabled
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$launchAtLogin
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$statusMessage
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$isStreamingChunkTranscribing
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$isTranscribing
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$isFinalizingStop
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
        model.$captureSourceMode
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
    }

    private func refreshMenuState() {
        recordItem?.title = model.isRecording ? "Stop Recording" : "Start Recording"
        streamingItem?.state = model.streamingEnabled ? .on : .off
        streamingItem?.isEnabled = model.transcriptionEnabled && model.captureSourceMode != .systemAudio
        sourceMicItem?.state = model.captureSourceMode == .microphone ? .on : .off
        sourceSystemItem?.state = model.captureSourceMode == .systemAudio ? .on : .off
        sourceMixedItem?.state = model.captureSourceMode == .mixed ? .on : .off
        launchAtLoginItem?.state = model.launchAtLogin ? .on : .off
        let isProcessing = model.isFinalizingStop || model.isTranscribing || model.isStreamingChunkTranscribing
        statusItem?.button?.image = statusIconImage(isRecording: model.isRecording, isProcessing: isProcessing)

        let shortState: String
        if model.isRecording {
            shortState = "Recording..."
        } else if isProcessing {
            shortState = model.transcriptionEnabled ? "Transcribing..." : "Processing..."
        } else {
            shortState = model.statusMessage
        }
        statusSummaryItem?.title = "Status: \(shortState)"
        updateTickerWindowVisibility()
    }

    private func statusIconImage(isRecording: Bool, isProcessing: Bool) -> NSImage? {
        if let custom = customStatusIcon(isRecording: isRecording, isProcessing: isProcessing) {
            return custom
        }

        let baseConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold, scale: .small)
        let symbolName = "waveform.circle.fill"
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Contora")?
            .withSymbolConfiguration(baseConfig) else {
            return nil
        }
        if #available(macOS 12.0, *) {
            let colors: [NSColor]
            if isRecording {
                colors = [.systemRed, .white]
            } else if isProcessing {
                colors = [.systemOrange, .white]
            } else {
                colors = [.systemGray, .labelColor]
            }
            let palette = NSImage.SymbolConfiguration(
                paletteColors: colors
            )
            if let colored = base.withSymbolConfiguration(palette) {
                colored.isTemplate = false
                return colored
            }
        }

        base.isTemplate = true
        statusItem?.button?.contentTintColor = isRecording ? .systemRed : (isProcessing ? .systemOrange : .labelColor)
        return base
    }

    private func customStatusIcon(isRecording: Bool, isProcessing: Bool) -> NSImage? {
        return nil
    }

    private func tickerWindow() -> NSWindow? {
        NSApp.windows.first
    }

    private func configureTickerWindowIfNeeded() {
        guard !didConfigureTickerWindow, let window = tickerWindow() else {
            return
        }
        didConfigureTickerWindow = true

        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.setContentSize(NSSize(width: 320, height: 36))
    }

    private func updateTickerWindowVisibility() {
        configureTickerWindowIfNeeded()
        guard let window = tickerWindow() else {
            return
        }
        let shouldShow = model.isRecording || model.isFinalizingStop || model.isTranscribing || model.isStreamingChunkTranscribing
        if shouldShow {
            positionTickerWindow(window)
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    private func positionTickerWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? window.screen else {
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.maxX - size.width - 20
        let y = visible.maxY - size.height - 6
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func openDashboard() {
        openLibraryWindow()
    }

    @objc private func openRecordingsFolder() {
        do {
            let directory = try RecordingArchiveService.recordingsDirectoryURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            model.statusMessage = "Failed to open recordings folder"
        }
    }

    @objc private func importAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            UTType(filenameExtension: "opus") ?? .audio
        ]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        model.importAudioFile(from: url)
    }

    @objc private func importVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .movie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        model.importVideoFile(from: url)
    }

    @objc private func toggleRecording() {
        model.toggleRecording()
    }

    @objc private func toggleStreaming() {
        model.streamingEnabled.toggle()
    }

    @objc private func setSourceMicrophone() {
        model.captureSourceMode = .microphone
    }

    @objc private func setSourceSystemAudio() {
        model.captureSourceMode = .systemAudio
    }

    @objc private func setSourceMixed() {
        model.captureSourceMode = .mixed
    }

    @objc private func toggleLaunchAtLogin() {
        model.launchAtLogin.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func openLibraryWindow() {
        let window: NSWindow
        if let existing = libraryWindow {
            window = existing
        } else {
            let contentView = SessionLibraryView(model: model)
            let hostingController = NSHostingController(rootView: contentView)
            let created = NSWindow(contentViewController: hostingController)
            created.title = "Contora Library"
            created.setContentSize(NSSize(width: 1120, height: 720))
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.center()
            libraryWindow = created
            window = created
        }

        model.reloadSessions()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? Color.red : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)

            Text(tickerText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 320, height: 36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tickerText: String {
        if model.isRecording && !model.lastTranscript.isEmpty && model.lastTranscript != "Recording in progress..." {
            return model.lastTranscript.replacingOccurrences(of: "\n", with: " ")
        }
        if model.isRecording {
            return "Recording..."
        }
        if model.isFinalizingStop || model.isTranscribing || model.isStreamingChunkTranscribing {
            let waited = Int(model.postStopWaitSeconds * 10) / 10
            let action = model.transcriptionEnabled ? "Transcribing" : "Processing"
            return "\(action)... \(waited)s"
        }
        if model.lastTranscript.isEmpty || model.lastTranscript == "No transcript yet." {
            return model.statusMessage
        }
        return model.lastTranscript.replacingOccurrences(of: "\n", with: " ")
    }
}

struct SessionLibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sessions")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Reload") {
                        model.reloadSessions()
                    }
                }

                Text(model.sessionLibraryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(selection: $model.selectedSessionID) {
                    ForEach(model.sessions) { session in
                        SessionRowView(session: session)
                            .tag(session.id)
                    }
                }
                .onChange(of: model.selectedSessionID) { _, newValue in
                    model.selectSession(newValue)
                }
            }
            .padding(16)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let session = model.selectedSession {
                SessionDetailView(model: model, session: session)
            } else {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("Record or import audio to create the first Contora session.")
                )
            }
        }
        .onAppear {
            model.reloadSessions()
        }
    }
}

struct SessionRowView: View {
    let session: ContoraSession

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            Text(Self.dateFormatter.string(from: session.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(session.transcriptPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.title)
                    .font(.title2.weight(.semibold))

                HStack(spacing: 12) {
                    Button("Open WAV") {
                        model.openURL(session.recordingURL)
                    }
                    if let transcriptURL = session.transcriptURL {
                        Button("Open TXT") {
                            model.openURL(transcriptURL)
                        }
                    }
                    if let jsonURL = session.jsonURL {
                        Button("Open JSON") {
                            model.openURL(jsonURL)
                        }
                    }
                    Button("Reveal in Finder") {
                        model.revealSession(session)
                    }
                    Spacer()
                    Button("Save Changes") {
                        model.saveSelectedSessionEdits()
                    }
                }

                SessionMetadataView(session: session)

                Text(model.sessionEditorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if !model.sessionEditorSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speakers")
                            .font(.headline)
                        ForEach(uniqueEditableSpeakers(), id: \.id) { speaker in
                            HStack {
                                Text(speaker.id)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 120, alignment: .leading)
                                TextField("Speaker name", text: Binding(
                                    get: { speaker.name },
                                    set: { model.updateSpeakerName(speakerID: speaker.id, newName: $0) }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    Divider()
                }

                if !model.sessionEditorSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Segments")
                            .font(.headline)
                        ForEach($model.sessionEditorSegments) { $segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(segment.timestampDisplay)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(segment.speakerID)
                                        .font(.caption.weight(.semibold))
                                    TextField("Speaker", text: $segment.speakerName)
                                        .textFieldStyle(.roundedBorder)
                                }
                                TextEditor(text: $segment.text)
                                    .font(.body)
                                    .frame(minHeight: 72)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.15))
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    Divider()
                }

                Text("Transcript")
                    .font(.headline)

                TextEditor(text: $model.sessionEditorTranscriptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .onAppear {
            model.selectSession(session.id)
        }
    }

    private func uniqueEditableSpeakers() -> [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(id: String, name: String)] = []
        for segment in model.sessionEditorSegments {
            if seen.insert(segment.speakerID).inserted {
                result.append((segment.speakerID, segment.speakerName))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}

struct SessionMetadataView: View {
    let session: ContoraSession

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Created", SessionRowView.dateFormatter.string(from: session.createdAt))
            row("Audio", durationText)
            row("Mode", session.metadata.mode ?? "Unknown")
            row("Language", session.metadata.language ?? "Unknown")
            row("Backend", session.metadata.endpoint ?? "Not recorded")
            row("Status", statusText)
        }
    }

    private var durationText: String {
        guard let seconds = session.metadata.audioSeconds else {
            return "Unknown"
        }
        let rounded = Int(seconds * 10) / 10
        return "\(rounded)s"
    }

    private var statusText: String {
        if let success = session.metadata.success {
            return success ? "Transcribed" : "Transcription failed"
        }
        return session.transcriptURL == nil ? "Recorded only" : "Transcript saved"
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Capture Source", selection: $model.captureSourceMode) {
                ForEach(CaptureSourceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Toggle("Enable Transcription (experimental)", isOn: $model.transcriptionEnabled)
            Picker("Transcription Backend", selection: $model.transcriptionBackend) {
                ForEach(TranscriptionBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            Toggle("Launch at Login", isOn: $model.launchAtLogin)
            Toggle("Enable Streaming by Default", isOn: $model.streamingEnabled)
                .disabled(!model.transcriptionEnabled || model.captureSourceMode == .systemAudio)
            Picker("Chunk Size", selection: $model.chunkSeconds) {
                Text("3s").tag(3)
                Text("8s").tag(8)
                Text("15s").tag(15)
            }
            .pickerStyle(.segmented)
            .disabled(!model.transcriptionEnabled)
            Picker("Recording Storage", selection: $model.recordingStoragePolicy) {
                ForEach(RecordingStoragePolicy.allCases) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }

            HStack {
                Text("Storage status: \(model.storageStatus)")
                Spacer()
            }
            TextField("Whisper endpoint URL", text: $model.transcriptionEndpoint)
                .disabled(!model.transcriptionEnabled || model.transcriptionBackend != .whisperHTTP)
            TextField("MLX endpoint URL", text: $model.mlxTranscriptionEndpoint)
                .disabled(!model.transcriptionEnabled || model.transcriptionBackend != .mlxOpenAIHTTP)
            TextField("MLX model ID", text: $model.mlxModelID)
                .disabled(!model.transcriptionEnabled || model.transcriptionBackend != .mlxOpenAIHTTP)
            TextField("Transcription language", text: $model.transcriptionLanguage)
                .disabled(!model.transcriptionEnabled)

            HStack {
                Text("Shared server config:")
                Spacer()
                Text(model.sharedServerConfigPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Text("Config status: \(model.sharedServerConfigStatus)")
                Spacer()
                Button("Reload") { model.loadSharedServerConfig() }
                Button("Save") { model.saveSharedServerConfig() }
            }

            HStack {
                Text("Backend probe: \(model.backendProbeStatus)")
                Spacer()
                Button("Check") { model.probeSharedBackend() }
            }

            Section("Diagnostics") {
                HStack {
                    Text("FFmpeg")
                    Spacer()
                    Text(model.diagnostics.ffmpegStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("FFmpeg path", model.diagnostics.ffmpegPath)
                diagnosticPathRow("FFmpeg version", model.diagnostics.ffmpegVersion)

                HStack {
                    Text("Shared runtime")
                    Spacer()
                    Text(model.diagnostics.sharedRuntimeRootStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Runtime root", model.diagnostics.sharedRuntimeRoot)

                HStack {
                    Text("Whisper executable")
                    Spacer()
                    Text(model.diagnostics.whisperExecutableStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Whisper path", model.diagnostics.whisperExecutablePath)

                HStack {
                    Text("Models directory")
                    Spacer()
                    Text(model.diagnostics.modelsDirectoryStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Models path", model.diagnostics.modelsDirectoryPath)

                HStack {
                    Text("Shared config")
                    Spacer()
                    Text(model.diagnostics.sharedConfigStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Config path", model.diagnostics.sharedConfigPath)
                diagnosticPathRow("Active backend", model.diagnostics.activeBackend)

                HStack {
                    Text("Shared model catalog")
                    Spacer()
                    Text(model.diagnostics.sharedModelCatalogStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Catalog path", model.diagnostics.sharedModelCatalogPath)
                diagnosticPathRow("Catalog summary", model.diagnostics.sharedModelCatalogSummary)

                if !model.sharedModelCatalogEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shared model entries")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.sharedModelCatalogEntries.prefix(8), id: \.id) { entry in
                            Text("\(entry.provider.rawValue) · \(entry.modelID) · \(entry.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                HStack {
                    Text("Shared MLX toolkit")
                    Spacer()
                    Text(model.diagnostics.sharedMLXToolkitStatus)
                        .foregroundStyle(.secondary)
                }
                diagnosticPathRow("Toolkit root", model.diagnostics.sharedMLXToolkitRoot)
                diagnosticPathRow("Toolkit log", model.diagnostics.sharedMLXLogPath)
                diagnosticPathRow("Toolkit action", model.sharedMLXToolkitActionStatus)

                HStack {
                    Button("Start MLX") { model.startSharedMLXToolkitServer() }
                        .disabled(model.diagnostics.sharedMLXToolkitStatus != "Present")
                    Button("Stop MLX") { model.stopSharedMLXToolkitServer() }
                        .disabled(model.diagnostics.sharedMLXToolkitStatus != "Present")
                    Button("Check MLX") { model.checkSharedMLXToolkitServer() }
                        .disabled(model.diagnostics.sharedMLXToolkitStatus != "Present")
                    Button("Open MLX Log") { model.openSharedMLXLog() }
                        .disabled(model.diagnostics.sharedMLXToolkitStatus != "Present")
                }

                HStack {
                    Spacer()
                    Button("Refresh Catalog") { model.refreshSharedModelCatalog() }
                    Button("Refresh Diagnostics") { model.refreshDiagnostics() }
                }
            }

            HStack {
                Text("Mic Permission: \(model.permissions.microphone.rawValue)")
                Spacer()
                Button("Request") { model.permissions.requestMicrophone() }
            }

            HStack {
                Text("Screen Recording: \(model.permissions.screenRecording.rawValue)")
                Spacer()
                Button("Request") { model.permissions.requestScreenRecording() }
            }

            Text("MVP mode: recording/transcription are local-first. Storage policy controls whether sessions keep WAV, add M4A, or switch to M4A only.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func diagnosticPathRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? "Not available" : value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFloat32LE(_ value: Float) {
        var bitPattern = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bitPattern) { append(contentsOf: $0) }
    }
}

private extension JSONEncoder {
    static var prettyISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct ContoraMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Contora", id: "dashboard") {
            DashboardView(model: AppModel.shared)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: AppModel.shared)
        }
    }
}

ContoraMacApp.main()
