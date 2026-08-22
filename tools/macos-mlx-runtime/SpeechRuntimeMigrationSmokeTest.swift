import Darwin
import Foundation

@main
struct SpeechRuntimeMigrationSmokeTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-speech-runtime-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv(SharedRuntimePaths.envRuntimeRoot, root.path, 1)

        try verifyRuntimeLayout(root: root)
        try verifyLegacySettingsMigration(root: root)
        try verifyCleanupIsNeverAutomatic(root: root)
        print("Speech runtime migration smoke test passed")
    }

    private static func verifyRuntimeLayout(root: URL) throws {
        guard SharedRuntimePaths.speechRuntimeRoot() == root.appendingPathComponent("speech-runtime", isDirectory: true),
              SharedRuntimePaths.speechRuntimePython().path.contains("speech-runtime/python/Python.framework"),
              SharedRuntimePaths.mlxVenvSitePackages().path.contains("speech-runtime/venv"),
              !SharedRuntimePaths.mlxServerScript().path.contains("faster-whisper-xxl") else {
            throw SmokeTestError.runtimeLayoutInvalid
        }
    }

    private static func verifyLegacySettingsMigration(root: URL) throws {
        let configURL = root.appendingPathComponent("transcription-server.json")
        let legacy = """
        {
          "schemaVersion": "1.0",
          "activeBackend": "faster_whisper_process",
          "whisperTranscribeURL": "http://127.0.0.1:5500/transcribe",
          "mlxTranscribeURL": "http://127.0.0.1:8010/v1/audio/transcriptions",
          "mlxModelID": "mlx-community/whisper-large-v3-turbo-asr-fp16",
          "mlxDiarizationEnabled": true,
          "fasterWhisperModelName": "large-v2",
          "fasterWhisperDiarizationEnabled": true,
          "updatedAt": "2026-08-22T00:00:00Z"
        }
        """
        try Data(legacy.utf8).write(to: configURL, options: .atomic)

        let config = try SharedTranscriptionServerConfigStore.shared.loadOrCreate()
        guard config.schemaVersion == "2.0",
              config.activeBackend == .mlxOpenAIHTTP,
              config.mlxModelID == "mlx-community/whisper-large-v3-turbo-asr-fp16",
              config.mlxDiarizationEnabled,
              config.fasterWhisperModelName.isEmpty,
              !config.fasterWhisperDiarizationEnabled,
              !TranscriptionBackend.allCases.contains(.fasterWhisperProcess),
              !TranscriptionBackend.allCases.contains(.whisperHTTP) else {
            throw SmokeTestError.settingsMigrationInvalid
        }

        let rewritten = try String(contentsOf: configURL, encoding: .utf8)
        guard rewritten.contains("mlx_openai_http"), !rewritten.contains("large-v2") else {
            throw SmokeTestError.settingsMigrationInvalid
        }

        let remoteLegacy = """
        {
          "schemaVersion": "2.0",
          "activeBackend": "whisper_http",
          "whisperTranscribeURL": "http://127.0.0.1:5500/transcribe",
          "mlxTranscribeURL": "http://127.0.0.1:8010/v1/audio/transcriptions",
          "mlxModelID": "mlx-community/whisper-large-v3-turbo-asr-fp16",
          "mlxDiarizationEnabled": true,
          "fasterWhisperModelName": "",
          "fasterWhisperDiarizationEnabled": false,
          "updatedAt": "2026-08-22T00:00:00Z"
        }
        """
        try Data(remoteLegacy.utf8).write(to: configURL, options: .atomic)
        let migratedRemote = try SharedTranscriptionServerConfigStore.shared.loadOrCreate()
        guard migratedRemote.activeBackend == .mlxOpenAIHTTP,
              try String(contentsOf: configURL, encoding: .utf8).contains("mlx_openai_http") else {
            throw SmokeTestError.settingsMigrationInvalid
        }
    }

    private static func verifyCleanupIsNeverAutomatic(root: URL) throws {
        let legacyRoot = root.appendingPathComponent("faster-whisper-xxl", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let report = LegacySpeechRuntimeCleanupService().audit()
        guard report.exists, FileManager.default.fileExists(atPath: legacyRoot.path) else {
            throw SmokeTestError.cleanupWasAutomatic
        }
    }
}

enum SmokeTestError: Error {
    case runtimeLayoutInvalid
    case settingsMigrationInvalid
    case cleanupWasAutomatic
}
