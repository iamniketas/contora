import Foundation

/// Shared runtime layout used by Contora and Dictator on macOS.
enum SharedRuntimePaths {
    static let envRuntimeRoot = "NIKETAS_SHARED_RUNTIME_ROOT"

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

    static func whisperKitModelsRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("whisperkit-models", isDirectory: true)
    }

    /// Self-contained runtime used by the managed macOS speech backend.
    /// The old `mlx-audio` and `faster-whisper-xxl` directories are retained
    /// only so another NiketasAI product can continue using them until the
    /// user explicitly removes the legacy runtime.
    static func speechRuntimeRoot() -> URL {
        sharedRuntimeRoot().appendingPathComponent("speech-runtime", isDirectory: true)
    }

    static func speechRuntimePython() -> URL {
        speechRuntimeRoot()
            .appendingPathComponent("python/Python.framework/Versions/3.12/bin/python3.12")
    }

    static func speechRuntimeSitePackages() -> URL {
        speechRuntimeRoot().appendingPathComponent("venv/lib/python3.12/site-packages", isDirectory: true)
    }

    static func speechRuntimeManifest() -> URL {
        speechRuntimeRoot().appendingPathComponent("runtime-manifest.json")
    }

    static func mlxVenvSitePackages() -> URL {
        speechRuntimeSitePackages()
    }

    static func mlxServerScript() -> URL {
        speechRuntimeRoot().appendingPathComponent("bin/contora_mlx_server.py")
    }

    static func mlxResultSafetyModule() -> URL {
        speechRuntimeRoot().appendingPathComponent("bin/result_safety.py")
    }

    static func mlxServerLog() -> URL {
        speechRuntimeRoot().appendingPathComponent("mlx-server.log")
    }

    static func mlxServerPIDFile() -> URL {
        speechRuntimeRoot().appendingPathComponent("mlx-server.pid")
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
