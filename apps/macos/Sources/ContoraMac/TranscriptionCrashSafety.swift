import Foundation

struct TranscriptionServerFailureEnvelope: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let code: String
        let message: String
        let stage: String
        let recoverable: Bool
    }

    let jobID: String
    let error: Failure

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case error
    }
}

struct MLXJobStatusEnvelope: Decodable, Sendable {
    let jobID: String
    let state: String
    let phase: String
    let message: String
    let progress: Double
    let processedSeconds: Double?
    let totalSeconds: Double?
    let elapsedSeconds: Double?
    let etaSeconds: Double?
    let error: TranscriptionServerFailureEnvelope.Failure?

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case phase
        case message
        case progress
        case processedSeconds = "processed_seconds"
        case totalSeconds = "total_seconds"
        case elapsedSeconds = "elapsed_seconds"
        case etaSeconds = "eta_seconds"
        case error
    }
}

struct MLXTranscriptionProgress: Sendable {
    let phase: String
    let fraction: Double
    let message: String
    let processedSeconds: Double?
    let totalSeconds: Double?
    let etaSeconds: Double?
}

struct MLXResultV2Envelope: Decodable, Sendable {
    struct Word: Decodable, Sendable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
        let speaker: String
        let speakerScore: Double
        let overlap: Bool
        let overlapSpeakers: [String]

        private enum CodingKeys: String, CodingKey {
            case text, start, end, confidence, speaker, overlap
            case speakerScore = "speaker_score"
            case overlapSpeakers = "overlap_speakers"
        }
    }

    struct SpeakerTurn: Decodable, Sendable {
        let start: Double
        let end: Double
        let speaker: String
        let confidence: Double?
    }

    struct Utterance: Decodable, Sendable {
        let start: Double
        let end: Double
        let speaker: String
        let text: String
        let wordStartIndex: Int
        let wordEndIndex: Int
        let overlap: Bool

        private enum CodingKeys: String, CodingKey {
            case start, end, speaker, text, overlap
            case wordStartIndex = "word_start_index"
            case wordEndIndex = "word_end_index"
        }
    }

    let schemaVersion: String
    let text: String
    let rawText: String
    let words: [Word]
    let speakerTurns: [SpeakerTurn]
    let utterances: [Utterance]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case text
        case rawText = "raw_text"
        case words
        case speakerTurns = "speaker_turns"
        case utterances
    }
}

struct MLXTranscriptionResponse: Sendable {
    let text: String
    let payloadData: Data
    let resultV2: MLXResultV2Envelope?
}

struct TranscriptionBackendOutput: Sendable {
    let text: String
    let structuredResultData: Data?
    let mlxResultV2: MLXResultV2Envelope?

    init(text: String, structuredResultData: Data? = nil, mlxResultV2: MLXResultV2Envelope? = nil) {
        self.text = text
        self.structuredResultData = structuredResultData
        self.mlxResultV2 = mlxResultV2
    }
}

struct MLXJobRecoveryRecord: Codable, Sendable, Equatable {
    let schemaVersion: String
    let localJobID: UUID
    let remoteJobID: String
    let sessionID: String
    let endpointURL: String
    let modelID: String
    let language: String
    let diarizationEnabled: Bool
    let audioSeconds: Double
    let createdAt: Date
}

struct MLXJobRecoveryStore: Sendable {
    let directoryURL: URL

    static func live() throws -> MLXJobRecoveryStore {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return MLXJobRecoveryStore(
            directoryURL: appSupport
                .appendingPathComponent("Contora", isDirectory: true)
                .appendingPathComponent("PendingTranscriptionJobs", isDirectory: true)
        )
    }

    func save(_ record: MLXJobRecoveryRecord) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let destination = fileURL(for: record.localJobID)
        try encoder.encode(record).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func loadAll() throws -> [MLXJobRecoveryRecord] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(MLXJobRecoveryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(localJobID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: localJobID))
    }

    private func fileURL(for localJobID: UUID) -> URL {
        directoryURL.appendingPathComponent(localJobID.uuidString.lowercased()).appendingPathExtension("json")
    }
}

struct ContoraSessionManifest: Codable {
    struct Files: Codable {
        let recordingWAV: String?
        let recordingM4A: String?
        let recordingMedia: String?
        let recordingExternalURL: String?
        let transcriptTXT: String?
        let transcriptJSON: String?
        let failureJSON: String?
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

        struct Word: Codable {
            let text: String
            let startSeconds: Double
            let endSeconds: Double
            let confidence: Double?
            let speakerID: String
            let speakerScore: Double
            let overlap: Bool
            let overlapSpeakers: [String]
        }

        struct SpeakerTurn: Codable {
            let startSeconds: Double
            let endSeconds: Double
            let speakerID: String
            let confidence: Double?
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
        let words: [Word]?
        let speakerTurns: [SpeakerTurn]?
    }

    struct Failure: Codable {
        let code: String
        let message: String
        let stage: String
        let recoverable: Bool
        let occurredAt: String
        let endpoint: String?
    }

    let schemaVersion: String
    let sessionID: String
    let title: String
    let createdAt: String
    let updatedAt: String
    let files: Files
    let capture: Capture
    let transcription: Transcription?
    let lastFailure: Failure?
}

enum TranscriptionFailureArtifactStore {
    private struct Artifact: Codable {
        let schemaVersion: String
        let sessionID: String
        let recordingFile: String
        let previousTranscriptPreserved: Bool
        let failure: ContoraSessionManifest.Failure
    }

    static func write(
        to url: URL,
        sessionID: String,
        recordingFile: String,
        previousTranscriptPreserved: Bool,
        failure: ContoraSessionManifest.Failure
    ) throws -> URL {
        let payload = Artifact(
            schemaVersion: "1.0",
            sessionID: sessionID,
            recordingFile: recordingFile,
            previousTranscriptPreserved: previousTranscriptPreserved,
            failure: failure
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: url, options: .atomic)
        return url
    }
}
