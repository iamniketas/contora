import Foundation

@main
struct ClientCrashSafetySmokeTest {
    static func main() throws {
        try verifyLegacyManifestCompatibility()
        try verifyFailureArtifactPreservesTranscript()
        try verifyStructuredServerFailure()
        try verifyMLXJobProgressStatus()
        try verifyMLXJobRecoveryStore()
        try verifyMLXResultV2Decoding()
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

    private static func verifyMLXJobRecoveryStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-mlx-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MLXJobRecoveryStore(directoryURL: root)
        let record = MLXJobRecoveryRecord(
            schemaVersion: "1.0",
            localJobID: UUID(),
            remoteJobID: "remote-job",
            sessionID: "session",
            endpointURL: "http://127.0.0.1:8010/v1/audio/transcriptions",
            modelID: "test-model",
            language: "ru",
            diarizationEnabled: true,
            audioSeconds: 600,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(record)
        guard try store.loadAll() == [record] else {
            throw SmokeTestError.recoveryStoreInvalid
        }
        store.remove(localJobID: record.localJobID)
        guard try store.loadAll().isEmpty else {
            throw SmokeTestError.recoveryStoreInvalid
        }
    }

    private static func verifyMLXResultV2Decoding() throws {
        let data = Data(
            """
            {
              "schema_version": "2.0",
              "text": "formatted",
              "raw_text": "Первый Второй",
              "words": [
                {"text":" Первый","start":0,"end":0.4,"confidence":0.9,"speaker":"SPEAKER_00","speaker_score":1,"overlap":false,"overlap_speakers":[]},
                {"text":" Второй","start":0.6,"end":1,"confidence":0.8,"speaker":"SPEAKER_01","speaker_score":1,"overlap":false,"overlap_speakers":[]}
              ],
              "speaker_turns": [
                {"start":0,"end":0.5,"speaker":"SPEAKER_00","confidence":null},
                {"start":0.5,"end":1,"speaker":"SPEAKER_01","confidence":null}
              ],
              "utterances": [
                {"start":0,"end":0.4,"speaker":"SPEAKER_00","text":"Первый","word_start_index":0,"word_end_index":1,"overlap":false},
                {"start":0.6,"end":1,"speaker":"SPEAKER_01","text":"Второй","word_start_index":1,"word_end_index":2,"overlap":false}
              ]
            }
            """.utf8
        )
        let result = try JSONDecoder().decode(MLXResultV2Envelope.self, from: data)
        guard result.schemaVersion == "2.0",
              result.words.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01"],
              result.utterances.count == 2 else {
            throw SmokeTestError.resultV2Invalid
        }
    }
}

enum SmokeTestError: Error {
    case legacyManifestIncompatible
    case transcriptWasOverwritten
    case failureArtifactInvalid
    case structuredFailureInvalid
    case jobProgressInvalid
    case recoveryStoreInvalid
    case resultV2Invalid
}
