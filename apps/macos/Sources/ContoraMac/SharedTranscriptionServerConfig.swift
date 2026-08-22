import Foundation

enum TranscriptionBackend: String, CaseIterable, Identifiable, Codable {
    case whisperHTTP = "whisper_http"
    case mlxOpenAIHTTP = "mlx_openai_http"
    case fasterWhisperProcess = "faster_whisper_process"

    var id: String { rawValue }

    /// Legacy values remain decoding tombstones for settings written by older
    /// Contora versions. The macOS product exposes only the managed MLX backend.
    static let allCases: [TranscriptionBackend] = [.mlxOpenAIHTTP]

    var title: String {
        switch self {
        case .whisperHTTP:
            return "Legacy backend (migrated)"
        case .mlxOpenAIHTTP:
            return "MLX OpenAI HTTP"
        case .fasterWhisperProcess:
            return "Legacy backend (migrated)"
        }
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        let decoded = TranscriptionBackend(rawValue: rawValue) ?? .mlxOpenAIHTTP
        self = decoded == .mlxOpenAIHTTP ? decoded : .mlxOpenAIHTTP
    }
}

struct SharedTranscriptionServerConfig: Codable {
    var schemaVersion: String
    var activeBackend: TranscriptionBackend
    var whisperTranscribeURL: String
    var mlxTranscribeURL: String
    var mlxModelID: String
    var mlxDiarizationEnabled: Bool
    var fasterWhisperModelName: String
    var fasterWhisperDiarizationEnabled: Bool
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeBackend
        case whisperTranscribeURL
        case mlxTranscribeURL
        case mlxModelID
        case mlxDiarizationEnabled
        case fasterWhisperModelName
        case fasterWhisperDiarizationEnabled
        case updatedAt
    }

    static func `default`() -> SharedTranscriptionServerConfig {
        SharedTranscriptionServerConfig(
            schemaVersion: "2.0",
            activeBackend: .mlxOpenAIHTTP,
            whisperTranscribeURL: "http://127.0.0.1:5500/transcribe",
            mlxTranscribeURL: "http://127.0.0.1:8010/v1/audio/transcriptions",
            mlxModelID: "mlx-community/whisper-large-v3-turbo-asr-fp16",
            mlxDiarizationEnabled: false,
            fasterWhisperModelName: "",
            fasterWhisperDiarizationEnabled: false,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    init(
        schemaVersion: String,
        activeBackend: TranscriptionBackend,
        whisperTranscribeURL: String,
        mlxTranscribeURL: String,
        mlxModelID: String,
        mlxDiarizationEnabled: Bool = false,
        fasterWhisperModelName: String,
        fasterWhisperDiarizationEnabled: Bool,
        updatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.activeBackend = activeBackend
        self.whisperTranscribeURL = whisperTranscribeURL
        self.mlxTranscribeURL = mlxTranscribeURL
        self.mlxModelID = mlxModelID
        self.mlxDiarizationEnabled = mlxDiarizationEnabled
        self.fasterWhisperModelName = fasterWhisperModelName
        self.fasterWhisperDiarizationEnabled = fasterWhisperDiarizationEnabled
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0"
        activeBackend = try values.decodeIfPresent(TranscriptionBackend.self, forKey: .activeBackend) ?? .mlxOpenAIHTTP
        whisperTranscribeURL = try values.decodeIfPresent(String.self, forKey: .whisperTranscribeURL) ?? "http://127.0.0.1:5500/transcribe"
        mlxTranscribeURL = try values.decodeIfPresent(String.self, forKey: .mlxTranscribeURL) ?? "http://127.0.0.1:8010/v1/audio/transcriptions"
        mlxModelID = try values.decodeIfPresent(String.self, forKey: .mlxModelID) ?? "mlx-community/whisper-large-v3-turbo-asr-fp16"
        mlxDiarizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .mlxDiarizationEnabled) ?? false
        fasterWhisperModelName = try values.decodeIfPresent(String.self, forKey: .fasterWhisperModelName) ?? ""
        fasterWhisperDiarizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .fasterWhisperDiarizationEnabled) ?? false
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ISO8601DateFormatter().string(from: Date())
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
            var config = try JSONDecoder().decode(SharedTranscriptionServerConfig.self, from: data)
            let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rawBackend = rawObject?["activeBackend"] as? String
            if config.schemaVersion != "2.0"
                || rawBackend != TranscriptionBackend.mlxOpenAIHTTP.rawValue
                || !config.fasterWhisperModelName.isEmpty
                || config.fasterWhisperDiarizationEnabled {
                config.schemaVersion = "2.0"
                config.activeBackend = .mlxOpenAIHTTP
                config.fasterWhisperModelName = ""
                config.fasterWhisperDiarizationEnabled = false
                try save(config)
            }
            return config
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

    func probe(backend: TranscriptionBackend, whisperURL: String, mlxURL: String, fasterWhisperModelName: String) async -> String {
        switch backend {
        case .whisperHTTP:
            return await probe(
                backend: .mlxOpenAIHTTP,
                whisperURL: whisperURL,
                mlxURL: mlxURL,
                fasterWhisperModelName: fasterWhisperModelName
            )

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

        case .fasterWhisperProcess:
            return await probe(
                backend: .mlxOpenAIHTTP,
                whisperURL: whisperURL,
                mlxURL: mlxURL,
                fasterWhisperModelName: fasterWhisperModelName
            )
        }
    }
}
