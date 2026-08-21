import Foundation

@main
struct ClientCrashSafetySmokeTest {
    static func main() throws {
        try verifyLegacyManifestCompatibility()
        try verifyFailureArtifactPreservesTranscript()
        try verifyStructuredServerFailure()
        try verifyMLXJobProgressStatus()
        print("Client crash-safety smoke test passed")
    }

    private static func verifyLegacyManifestCompatibility() throws {
        let json = """
        {
          "schemaVersion": "1.0",
          "sessionID": "legacy-session",
          "title": "Legacy",
          "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-01T10:01:00Z",
          "files": {
            "recordingWAV": "legacy.wav",
            "recordingM4A": null,
            "recordingMedia": "legacy.wav",
            "recordingExternalURL": null,
            "transcriptTXT": "legacy.txt",
            "transcriptJSON": "legacy.json"
          },
          "capture": {
            "sourceMode": "Imported Audio",
            "audioSeconds": 60,
            "sampleRate": 16000,
            "channels": 1
          },
          "transcription": null
        }
        """
        let manifest = try JSONDecoder().decode(ContoraSessionManifest.self, from: Data(json.utf8))
        guard manifest.sessionID == "legacy-session",
              manifest.files.failureJSON == nil,
              manifest.lastFailure == nil else {
            throw SmokeTestError.legacyManifestIncompatible
        }
    }

    private static func verifyFailureArtifactPreservesTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-client-crash-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("session.txt")
        let failureURL = root.appendingPathComponent("session.failed.json")
        let originalTranscript = "[00:00:00.000 --> 00:00:01.000] [SPEAKER_00]: Успешный текст"
        try originalTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let failure = ContoraSessionManifest.Failure(
            code: "SerializationError",
            message: "Non-finite diagnostic value",
            stage: "serializing",
            recoverable: true,
            occurredAt: "2026-08-21T18:00:00Z",
            endpoint: "http://127.0.0.1:8010/v1/audio/transcriptions"
        )
        _ = try TranscriptionFailureArtifactStore.write(
            to: failureURL,
            sessionID: "session",
            recordingFile: "session.wav",
            previousTranscriptPreserved: true,
            failure: failure
        )

        guard try String(contentsOf: transcriptURL, encoding: .utf8) == originalTranscript else {
            throw SmokeTestError.transcriptWasOverwritten
        }
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: failureURL)) as? [String: Any]
        guard payload?["previousTranscriptPreserved"] as? Bool == true,
              (payload?["failure"] as? [String: Any])?["stage"] as? String == "serializing" else {
            throw SmokeTestError.failureArtifactInvalid
        }
    }

    private static func verifyStructuredServerFailure() throws {
        let data = Data(
            """
            {
              "job_id": "job-123",
              "state": "failed",
              "error": {
                "code": "ResponseValidationError",
                "message": "invalid segment",
                "stage": "serializing",
                "recoverable": true
              }
            }
            """.utf8
        )
        let envelope = try JSONDecoder().decode(TranscriptionServerFailureEnvelope.self, from: data)
        guard envelope.jobID == "job-123",
              envelope.error.stage == "serializing",
              envelope.error.recoverable else {
            throw SmokeTestError.structuredFailureInvalid
        }
    }

    private static func verifyMLXJobProgressStatus() throws {
        let data = Data(
            """
            {
              "job_id": "job-progress",
              "state": "diarizing",
              "phase": "diarizing",
              "message": "Detecting speakers · Embeddings",
              "progress": 0.81,
              "processed_seconds": 1200,
              "total_seconds": 3600,
              "elapsed_seconds": 180,
              "eta_seconds": 42,
              "error": null
            }
            """.utf8
        )
        let status = try JSONDecoder().decode(MLXJobStatusEnvelope.self, from: data)
        guard status.jobID == "job-progress",
              status.phase == "diarizing",
              status.progress == 0.81,
              status.etaSeconds == 42 else {
            throw SmokeTestError.jobProgressInvalid
        }
    }
}

enum SmokeTestError: Error {
    case legacyManifestIncompatible
    case transcriptWasOverwritten
    case failureArtifactInvalid
    case structuredFailureInvalid
    case jobProgressInvalid
}
