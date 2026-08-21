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
