import Foundation

enum TranscriptionBackend: String, CaseIterable, Identifiable, Codable {
    case whisperHTTP = "whisper_http"
    case mlxOpenAIHTTP = "mlx_openai_http"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisperHTTP:
            return "Whisper HTTP"
        case .mlxOpenAIHTTP:
            return "MLX OpenAI HTTP"
        }
    }
}

struct SharedTranscriptionServerConfig: Codable {
    var schemaVersion: String
    var activeBackend: TranscriptionBackend
    var whisperTranscribeURL: String
    var mlxTranscribeURL: String
    var mlxModelID: String
    var updatedAt: String

    static func `default`() -> SharedTranscriptionServerConfig {
        SharedTranscriptionServerConfig(
            schemaVersion: "1.0",
            activeBackend: .mlxOpenAIHTTP,
            whisperTranscribeURL: "http://127.0.0.1:5500/transcribe",
            mlxTranscribeURL: "http://127.0.0.1:8000/v1/audio/transcriptions",
            mlxModelID: "mlx-community/whisper-large-v3-turbo-asr-fp16",
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}

enum SharedTranscriptionServerError: LocalizedError {
    case invalidConfigPath

    var errorDescription: String? {
        switch self {
        case .invalidConfigPath:
            return "Shared transcription server config path is invalid."
        }
    }
}

final class SharedTranscriptionServerConfigStore {
    static let shared = SharedTranscriptionServerConfigStore()

    private init() {}

    func loadOrCreate() throws -> SharedTranscriptionServerConfig {
        let path = configFileURL()
        let fm = FileManager.default

        if fm.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode(SharedTranscriptionServerConfig.self, from: data)
        }

        let config = SharedTranscriptionServerConfig.default()
        try save(config)
        return config
    }

    func save(_ config: SharedTranscriptionServerConfig) throws {
        let url = configFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var value = config
        value.updatedAt = ISO8601DateFormatter().string(from: Date())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func configFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["NIKETAS_SHARED_SERVER_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return SharedRuntimePaths.sharedRuntimeRoot()
            .appendingPathComponent("transcription-server.json")
    }

    func probe(backend: TranscriptionBackend, whisperURL: String, mlxURL: String) async -> String {
        switch backend {
        case .whisperHTTP:
            guard let transcribeURL = URL(string: whisperURL),
                  var components = URLComponents(url: transcribeURL, resolvingAgainstBaseURL: false) else {
                return "Whisper: invalid URL"
            }
            components.path = "/health"
            guard let healthURL = components.url else {
                return "Whisper: invalid health URL"
            }
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                guard let http = response as? HTTPURLResponse else {
                    return "Whisper: bad response"
                }
                return (200...299).contains(http.statusCode) ? "Whisper: OK (/health)" : "Whisper: HTTP \(http.statusCode)"
            } catch {
                return "Whisper probe failed: \(error.localizedDescription)"
            }

        case .mlxOpenAIHTTP:
            guard let transcribeURL = URL(string: mlxURL),
                  var components = URLComponents(url: transcribeURL, resolvingAgainstBaseURL: false) else {
                return "MLX: invalid URL"
            }
            components.path = "/v1/models"
            guard let modelsURL = components.url else {
                return "MLX: invalid models URL"
            }
            do {
                let (_, response) = try await URLSession.shared.data(from: modelsURL)
                guard let http = response as? HTTPURLResponse else {
                    return "MLX: bad response"
                }
                return (200...299).contains(http.statusCode) ? "MLX: OK (/v1/models)" : "MLX: HTTP \(http.statusCode)"
            } catch {
                return "MLX probe failed: \(error.localizedDescription)"
            }
        }
    }
}
