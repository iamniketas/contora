import Foundation

struct AppUpdateInfo: Identifiable {
    let version: String
    let releaseName: String
    let releaseURL: URL
    let assetName: String
    let assetURL: URL
    let assetSizeBytes: Int64
    let publishedAt: Date?

    var id: String { version }

    var assetSizeDisplay: String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(max(0, assetSizeBytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

enum AppUpdateError: LocalizedError {
    case invalidRepository
    case invalidResponse
    case releaseUnavailable
    case macOSAssetUnavailable
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Update repository is not configured."
        case .invalidResponse:
            return "GitHub returned an unexpected update response."
        case .releaseUnavailable:
            return "Could not find the latest Contora release."
        case .macOSAssetUnavailable:
            return "The latest release does not include a macOS app asset for this Mac."
        case .downloadFailed:
            return "Update download failed."
        }
    }
}

final class AppUpdateService {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let size: Int64

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let name: String?
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let bundleVersion = info?["CFBundleVersion"] as? String
        let version = shortVersion ?? bundleVersion
        return version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? version!
            : "0.0.0-dev"
    }

    private let session: URLSession
    private let repositoryOwner: String
    private let repositoryName: String

    init(
        session: URLSession = .shared,
        repositoryOwner: String = ProcessInfo.processInfo.environment["CONTORA_UPDATE_REPO_OWNER"] ?? "iamniketas",
        repositoryName: String = ProcessInfo.processInfo.environment["CONTORA_UPDATE_REPO_NAME"] ?? "contora"
    ) {
        self.session = session
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
    }

    func checkForUpdate(currentVersion: String = AppUpdateService.currentAppVersion) async throws -> AppUpdateInfo? {
        guard !repositoryOwner.isEmpty, !repositoryName.isEmpty else {
            throw AppUpdateError.invalidRepository
        }

        let apiURL = URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("ContoraMac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        guard http.statusCode != 404 else {
            throw AppUpdateError.releaseUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppUpdateError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let latestVersion = Self.normalizedVersion(release.tagName)

        guard Self.compareVersions(latestVersion, currentVersion) == .orderedDescending else {
            return nil
        }
        guard let asset = preferredMacOSAsset(in: release.assets) else {
            throw AppUpdateError.macOSAssetUnavailable
        }

        return AppUpdateInfo(
            version: latestVersion,
            releaseName: release.name ?? release.tagName,
            releaseURL: release.htmlURL,
            assetName: asset.name,
            assetURL: asset.browserDownloadURL,
            assetSizeBytes: asset.size,
            publishedAt: release.publishedAt
        )
    }

    func download(update: AppUpdateInfo) async throws -> URL {
        var request = URLRequest(url: update.assetURL)
        request.setValue("ContoraMac/\(Self.currentAppVersion)", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppUpdateError.downloadFailed
        }

        let destination = try uniqueDownloadDestination(fileName: update.assetName)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func preferredMacOSAsset(in assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        let appAssets = assets.filter { asset in
            let lower = asset.name.lowercased()
            guard !lower.contains("whisperruntime"),
                  !lower.contains("runtime"),
                  !lower.contains("setup.exe"),
                  lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg") || lower.hasSuffix(".zip")
            else {
                return false
            }

            return lower.contains("macos")
                || lower.contains("mac-os")
                || lower.contains("darwin")
                || lower.contains(Self.currentArchitecture)
                || lower.contains("universal")
        }

        let compatibleAssets = appAssets.filter {
            let lower = $0.name.lowercased()
            return lower.contains(Self.currentArchitecture) || lower.contains("universal")
        }
        let candidates = compatibleAssets.isEmpty ? appAssets : compatibleAssets
        let extensionPriority = ["dmg": 0, "pkg": 1, "zip": 2]

        return candidates.sorted { lhs, rhs in
            let lhsExt = lhs.name.split(separator: ".").last.map(String.init) ?? ""
            let rhsExt = rhs.name.split(separator: ".").last.map(String.init) ?? ""
            let lhsPriority = extensionPriority[lhsExt.lowercased()] ?? 9
            let rhsPriority = extensionPriority[rhsExt.lowercased()] ?? 9
            if lhsPriority == rhsPriority {
                return lhs.name < rhs.name
            }
            return lhsPriority < rhsPriority
        }.first
    }

    private func uniqueDownloadDestination(fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let baseURL = downloadsDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        for index in 1...100 {
            let candidate = downloadsDirectory
                .appendingPathComponent("\(name)-\(index)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return downloadsDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "universal"
        #endif
    }

    private static func normalizedVersion(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericVersionComponents(lhs)
        let right = numericVersionComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersionComponents(_ value: String) -> [Int] {
        normalizedVersion(value)
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}
