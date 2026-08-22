import Foundation

enum SharedModelProvider: String, Codable, CaseIterable {
    case whisperKit = "whisperkit"
    case fasterWhisper = "faster-whisper"
    case mlxAudio = "mlx-audio"
    case ollama = "ollama"
}

struct SharedModelCatalogEntry: Codable, Hashable, Identifiable {
    let id: String
    let provider: SharedModelProvider
    let modelID: String
    let path: String
    let source: String
    let status: String
    let updatedAt: String
}

struct SharedModelCatalog: Codable {
    let schemaVersion: String
    let generatedAt: String
    let entries: [SharedModelCatalogEntry]
}

final class SharedModelCatalogStore {
    static let shared = SharedModelCatalogStore()

    private init() {}

    func catalogURL() -> URL {
        SharedRuntimePaths.modelCatalogURL()
    }

    func loadOrCreate() throws -> SharedModelCatalog {
        let url = catalogURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SharedModelCatalog.self, from: data)
        }

        let catalog = scan()
        try save(catalog)
        return catalog
    }

    func save(_ catalog: SharedModelCatalog) throws {
        let url = catalogURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: url, options: .atomic)
    }

    func refresh() throws -> SharedModelCatalog {
        let catalog = scan()
        try save(catalog)
        return catalog
    }

    private func scan() -> SharedModelCatalog {
        let now = ISO8601DateFormatter().string(from: Date())
        var entries: [SharedModelCatalogEntry] = []

        entries.append(contentsOf: scanWhisperKit(now: now))
        entries.append(contentsOf: scanMLX(now: now))
        entries.append(contentsOf: scanOllama(now: now))

        return SharedModelCatalog(
            schemaVersion: "1.0",
            generatedAt: now,
            entries: entries.sorted { lhs, rhs in
                if lhs.provider.rawValue == rhs.provider.rawValue {
                    return lhs.modelID < rhs.modelID
                }
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
        )
    }

    private func scanWhisperKit(now: String) -> [SharedModelCatalogEntry] {
        let fileManager = FileManager.default
        let roots = [
            ("shared", SharedRuntimePaths.whisperKitModelsRoot()),
            ("dictator-legacy", SharedRuntimePaths.dictatorLegacyWhisperKitModelsRoot())
        ]

        var entries: [SharedModelCatalogEntry] = []
        for (source, root) in roots {
            guard let directories = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for directory in directories where containsWhisperKitModelFiles(directory) {
                entries.append(
                    SharedModelCatalogEntry(
                        id: "whisperkit::\(directory.lastPathComponent)::\(source)",
                        provider: .whisperKit,
                        modelID: directory.lastPathComponent,
                        path: directory.path,
                        source: source,
                        status: "available",
                        updatedAt: now
                    )
                )
            }
        }
        return entries
    }

    private func containsWhisperKitModelFiles(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }

        var hasMel = false
        var hasEncoder = false
        var hasDecoder = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name.contains("melspectrogram") { hasMel = true }
            if name.contains("audioencoder") { hasEncoder = true }
            if name.contains("textdecoder") { hasDecoder = true }
            if hasMel && hasEncoder && hasDecoder {
                return true
            }
        }
        return false
    }

    private func scanMLX(now: String) -> [SharedModelCatalogEntry] {
        var entries: [SharedModelCatalogEntry] = []
        if let config = try? SharedTranscriptionServerConfigStore.shared.loadOrCreate(),
           !config.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cacheURL = huggingFaceCacheURL(forModelID: config.mlxModelID)
            entries.append(
                SharedModelCatalogEntry(
                    id: "mlx-audio::\(config.mlxModelID)",
                    provider: .mlxAudio,
                    modelID: config.mlxModelID,
                    path: cacheURL?.path ?? config.mlxModelID,
                    source: cacheURL == nil ? "configured" : "huggingface-cache",
                    status: cacheURL == nil ? "configured" : "available",
                    updatedAt: now
                )
            )
        }

        let sharedRoot = SharedRuntimePaths.speechRuntimeRoot()
        if FileManager.default.fileExists(atPath: sharedRoot.path) {
            entries.append(
                SharedModelCatalogEntry(
                    id: "mlx-audio::shared-root",
                    provider: .mlxAudio,
                    modelID: "shared-root",
                    path: sharedRoot.path,
                    source: "shared",
                    status: "available",
                    updatedAt: now
                )
            )

            let modelsRoot = sharedRoot.appendingPathComponent("models", isDirectory: true)
            if let modelDirectories = try? FileManager.default.contentsOfDirectory(
                at: modelsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                entries.append(contentsOf: modelDirectories.map { directory in
                    SharedModelCatalogEntry(
                        id: "mlx-audio::shared::\(directory.lastPathComponent)",
                        provider: .mlxAudio,
                        modelID: directory.lastPathComponent,
                        path: directory.path,
                        source: "shared",
                        status: "available",
                        updatedAt: now
                    )
                })
            }
        }

        return entries
    }

    private func huggingFaceCacheURL(forModelID modelID: String) -> URL? {
        let cacheName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub/\(cacheName)", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/huggingface/hub/\(cacheName)", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func scanOllama(now: String) -> [SharedModelCatalogEntry] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ollama/models", isDirectory: true)

        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        return [
            SharedModelCatalogEntry(
                id: "ollama::models",
                provider: .ollama,
                modelID: "models",
                path: root.path,
                source: "user-home",
                status: "available",
                updatedAt: now
            )
        ]
    }
}
