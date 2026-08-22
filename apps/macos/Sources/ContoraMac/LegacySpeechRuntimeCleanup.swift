import Foundation

struct LegacySpeechRuntimeCleanupReport {
    let runtimeURL: URL
    let exists: Bool
    let blockers: [String]

    var canMoveToTrash: Bool { exists && blockers.isEmpty }

    var displayText: String {
        if !exists { return "No legacy runtime found" }
        if blockers.isEmpty { return "Legacy runtime can be moved to Trash" }
        return "Cleanup blocked: \(blockers.joined(separator: "; "))"
    }
}

enum LegacySpeechRuntimeCleanupError: LocalizedError {
    case unsafeTarget
    case blocked([String])

    var errorDescription: String? {
        switch self {
        case .unsafeTarget:
            return "Refusing to remove a legacy runtime outside the expected shared runtime directory."
        case let .blocked(reasons):
            return "Legacy runtime is still potentially in use: \(reasons.joined(separator: "; "))"
        }
    }
}

/// Audits the shared legacy runtime before offering a recoverable, explicit
/// move to Trash. Nothing invokes cleanup automatically.
final class LegacySpeechRuntimeCleanupService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func audit() -> LegacySpeechRuntimeCleanupReport {
        let runtimeURL = SharedRuntimePaths.whisperRoot().standardizedFileURL
        guard fileManager.fileExists(atPath: runtimeURL.path) else {
            return LegacySpeechRuntimeCleanupReport(runtimeURL: runtimeURL, exists: false, blockers: [])
        }

        var blockers: [String] = []
        if isSymbolicLink(runtimeURL) {
            blockers.append("runtime path is a symbolic link")
        }
        if dictatorApplicationIsInstalled() {
            blockers.append("Dictator is installed")
        }

        guard let commands = processCommands() else {
            blockers.append("running-process audit was unavailable")
            return LegacySpeechRuntimeCleanupReport(runtimeURL: runtimeURL, exists: true, blockers: blockers)
        }
        let referencingProcesses = commands.filter {
            $0.localizedCaseInsensitiveContains(runtimeURL.path)
                || ($0.localizedCaseInsensitiveContains("dictator")
                    && $0.localizedCaseInsensitiveContains("whisper"))
        }
        if !referencingProcesses.isEmpty {
            blockers.append("a running process references the legacy runtime")
        }

        if dictatorConfigurationReferencesLegacyRuntime(runtimeURL) {
            blockers.append("Dictator configuration references the legacy runtime")
        }

        return LegacySpeechRuntimeCleanupReport(
            runtimeURL: runtimeURL,
            exists: true,
            blockers: Array(Set(blockers)).sorted()
        )
    }

    @discardableResult
    func moveToTrash() throws -> URL? {
        let report = audit()
        guard report.exists else { return nil }
        guard report.canMoveToTrash else {
            throw LegacySpeechRuntimeCleanupError.blocked(report.blockers)
        }

        let expectedParent = SharedRuntimePaths.sharedRuntimeRoot().standardizedFileURL
        guard report.runtimeURL.deletingLastPathComponent().standardizedFileURL == expectedParent,
              report.runtimeURL.lastPathComponent == "faster-whisper-xxl",
              !isSymbolicLink(report.runtimeURL) else {
            throw LegacySpeechRuntimeCleanupError.unsafeTarget
        }

        var resultingURL: NSURL?
        try fileManager.trashItem(at: report.runtimeURL, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return true }
        return type == .typeSymbolicLink
    }

    private func dictatorApplicationIsInstalled() -> Bool {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Dictator.app", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Dictator.app", isDirectory: true),
        ]
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    private func dictatorConfigurationReferencesLegacyRuntime(_ runtimeURL: URL) -> Bool {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictator", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 1_000_000,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if text.localizedCaseInsensitiveContains(runtimeURL.path)
                || text.localizedCaseInsensitiveContains("faster-whisper-xxl") {
                return true
            }
        }
        return false
    }

    private func processCommands() -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map(String.init)
        } catch {
            return nil
        }
    }
}
