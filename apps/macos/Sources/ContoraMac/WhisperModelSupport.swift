import Foundation

struct WhisperModelOption: Identifiable, Hashable {
    let name: String
    let displayName: String
    let detail: String

    var id: String { name }

    static let fasterWhisperOptions: [WhisperModelOption] = [
        .init(name: "tiny", displayName: "tiny", detail: "Fastest, lowest quality"),
        .init(name: "base", displayName: "base", detail: "Light CPU fallback"),
        .init(name: "small", displayName: "small", detail: "Balanced CPU option"),
        .init(name: "medium", displayName: "medium", detail: "Better quality, slower"),
        .init(name: "large-v2", displayName: "large-v2", detail: "Stable diarization baseline"),
        .init(name: "large-v3", displayName: "large-v3", detail: "Higher quality, larger model")
    ]

    static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "large-v2" : trimmed
    }
}

struct WhisperModelDownloadProgress {
    let percent: Int
    let downloadedBytes: Int64
    let totalBytes: Int64
    let currentFile: String
}

enum WhisperModelDownloadError: LocalizedError {
    case runtimeMissing(URL)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .runtimeMissing(url):
            return "Faster Whisper runtime is missing at \(url.path)"
        case let .downloadFailed(message):
            return message
        }
    }
}

struct FasterWhisperModelDownloadService {
    private static let fallbackModelFiles = ["config.json", "tokenizer.json", "vocabulary.txt", "model.bin"]

    let modelName: String

    var modelDirectory: URL {
        SharedRuntimePaths.modelDirectory(name: modelName)
    }

    var repositoryResolveURL: URL {
        URL(string: "https://huggingface.co/Systran/faster-whisper-\(modelName)/resolve/main")!
    }

    func isInstalled() -> Bool {
        SharedRuntimePaths.isFasterWhisperModelInstalled(name: modelName)
    }

    func download(onProgress: @escaping (WhisperModelDownloadProgress) -> Void) async throws {
        guard FileManager.default.isExecutableFile(atPath: SharedRuntimePaths.whisperExecutable().path) else {
            throw WhisperModelDownloadError.runtimeMissing(SharedRuntimePaths.whisperExecutable())
        }

        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let modelFiles = await resolveModelFiles()
        let totalBytes = await resolveTotalBytes(modelFiles: modelFiles)
        var downloadedBytes: Int64 = 0

        for fileName in modelFiles {
            try Task.checkCancellation()

            let targetURL = modelDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                downloadedBytes += Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                onProgress(.init(percent: percent(downloadedBytes: downloadedBytes, totalBytes: totalBytes), downloadedBytes: downloadedBytes, totalBytes: totalBytes, currentFile: fileName))
                continue
            }

            let sourceURL = repositoryResolveURL.appendingPathComponent(fileName)
            let temporaryURL = targetURL.appendingPathExtension("download")
            try? FileManager.default.removeItem(at: temporaryURL)

            let (downloadedURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw WhisperModelDownloadError.downloadFailed("Failed to download \(fileName) for \(modelName)")
            }

            try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: targetURL)

            downloadedBytes += Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            onProgress(.init(percent: percent(downloadedBytes: downloadedBytes, totalBytes: totalBytes), downloadedBytes: downloadedBytes, totalBytes: totalBytes, currentFile: fileName))
        }
    }

    private func resolveModelFiles() async -> [String] {
        guard let apiURL = URL(string: "https://huggingface.co/api/models/Systran/faster-whisper-\(modelName)") else {
            return Self.fallbackModelFiles
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: apiURL)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                return Self.fallbackModelFiles
            }

            let payload = try JSONDecoder().decode(HuggingFaceModelPayload.self, from: data)
            let files = payload.siblings
                .map(\.rfilename)
                .filter { fileName in
                    !fileName.hasPrefix(".") && fileName.lowercased() != "readme.md"
                }
                .sorted()
            return files.isEmpty ? Self.fallbackModelFiles : files
        } catch {
            return Self.fallbackModelFiles
        }
    }

    private func resolveTotalBytes(modelFiles: [String]) async -> Int64 {
        var total: Int64 = 0
        for fileName in modelFiles {
            guard let url = URL(string: "\(repositoryResolveURL.absoluteString)/\(fileName)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            if
                let (_, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
                let value = Int64(contentLength)
            {
                total += value
            }
        }
        return total
    }

    private func percent(downloadedBytes: Int64, totalBytes: Int64) -> Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, Int((downloadedBytes * 100) / totalBytes))
    }
}

private struct HuggingFaceModelPayload: Decodable {
    let siblings: [HuggingFaceModelFile]
}

private struct HuggingFaceModelFile: Decodable {
    let rfilename: String
}
