import Foundation

/// Shared runtime layout used by Contora and Dictator on macOS.
enum SharedRuntimePaths {
    static let envRuntimeRoot = "NIKETAS_SHARED_RUNTIME_ROOT"
    static let envWhisperExecutable = "CONTORA_WHISPER_EXE"

    static func sharedRuntimeRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment[envRuntimeRoot], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("NiketasAI/runtime", isDirectory: true)
        }

        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/NiketasAI/runtime", isDirectory: true)
    }

    static func whisperRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("faster-whisper-xxl", isDirectory: true)
    }

    static func whisperExecutable() -> URL {
        if let env = ProcessInfo.processInfo.environment[envWhisperExecutable], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return whisperRoot().appendingPathComponent("faster-whisper-xxl")
    }

    static func modelsDirectory() -> URL {
        whisperRoot().appendingPathComponent("_models", isDirectory: true)
    }

    static func modelDirectory(name: String) -> URL {
        modelsDirectory().appendingPathComponent("faster-whisper-\(name)", isDirectory: true)
    }

    static func whisperKitModelsRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("whisperkit-models", isDirectory: true)
    }

    static func mlxAudioRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("mlx-audio", isDirectory: true)
    }

    static func localLLMRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("llm", isDirectory: true)
    }

    static func modelCatalogURL() -> URL {
        sharedRuntimeRoot().appendingPathComponent("model-catalog.json")
    }

    static func dictatorLegacyWhisperKitModelsRoot() -> URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("Dictator", isDirectory: true)
                .appendingPathComponent("WhisperKitModels", isDirectory: true)
        }

        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictator/WhisperKitModels", isDirectory: true)
    }
}
