import Foundation

struct DeletedSessionSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let deletedAt: Date
    let fileNames: [String]
}

enum SessionManagementError: LocalizedError {
    case emptyTitle
    case sessionNotFound
    case alreadyDeleted
    case restoreConflict(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "A session title cannot be empty."
        case .sessionNotFound:
            return "The session files could not be found."
        case .alreadyDeleted:
            return "This session is already in Recently Deleted."
        case let .restoreConflict(fileName):
            return "Cannot restore because \(fileName) already exists."
        }
    }
}

final class SessionManagementService {
    private let fileManager = FileManager.default
    private let metadataFileName = "deleted-session.json"
    private let rootURLProvider: () throws -> URL

    init(rootURLProvider: @escaping () throws -> URL = RecordingArchiveService.recordingsDirectoryURL) {
        self.rootURLProvider = rootURLProvider
    }

    func renameSession(id: String, to proposedTitle: String) throws {
        let title = proposedTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SessionManagementError.emptyTitle }

        let root = try rootURLProvider()
        let manifestURL = root.appendingPathComponent(id).appendingPathExtension("session.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SessionManagementError.sessionNotFound
            }
            object["title"] = String(title.prefix(200))
            object["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            let updatedData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try updatedData.write(to: manifestURL, options: .atomic)
            return
        }

        let legacyAudioExists = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).contains { url in
            url.deletingPathExtension().lastPathComponent == id
                && ["wav", "m4a"].contains(url.pathExtension.lowercased())
        }
        guard legacyAudioExists else { throw SessionManagementError.sessionNotFound }
        try String(title.prefix(200)).write(
            to: titleOverrideURL(sessionID: id, root: root),
            atomically: true,
            encoding: .utf8
        )
    }

    func moveToRecentlyDeleted(sessionID: String, title: String) throws {
        let root = try rootURLProvider()
        let trashRoot = recentlyDeletedDirectory(root: root)
        try fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)

        let destination = trashRoot.appendingPathComponent(sessionID, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SessionManagementError.alreadyDeleted
        }

        let candidates = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("\(sessionID).") }
        guard !candidates.isEmpty else { throw SessionManagementError.sessionNotFound }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var movedFiles: [URL] = []
        do {
            for source in candidates {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: target)
                movedFiles.append(target)
            }

            let summary = DeletedSessionSummary(
                id: sessionID,
                title: title,
                deletedAt: Date(),
                fileNames: candidates.map(\.lastPathComponent).sorted()
            )
            let data = try JSONEncoder.sessionManagement.encode(summary)
            try data.write(to: destination.appendingPathComponent(metadataFileName), options: .atomic)
        } catch {
            for movedURL in movedFiles.reversed() {
                try? fileManager.moveItem(at: movedURL, to: root.appendingPathComponent(movedURL.lastPathComponent))
            }
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func loadRecentlyDeleted() throws -> [DeletedSessionSummary] {
        let root = try rootURLProvider()
        let trashRoot = recentlyDeletedDirectory(root: root)
        guard fileManager.fileExists(atPath: trashRoot.path) else { return [] }

        let directories = try fileManager.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            let metadataURL = directory.appendingPathComponent(metadataFileName)
            guard let data = try? Data(contentsOf: metadataURL) else { return nil }
            return try? JSONDecoder.sessionManagement.decode(DeletedSessionSummary.self, from: data)
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ deletedSession: DeletedSessionSummary) throws {
        let root = try rootURLProvider()
        let sourceDirectory = recentlyDeletedDirectory(root: root)
            .appendingPathComponent(deletedSession.id, isDirectory: true)
        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            throw SessionManagementError.sessionNotFound
        }

        for fileName in deletedSession.fileNames {
            let destination = root.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destination.path) {
                throw SessionManagementError.restoreConflict(fileName)
            }
        }

        var restoredFiles: [URL] = []
        do {
            for fileName in deletedSession.fileNames {
                let source = sourceDirectory.appendingPathComponent(fileName)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = root.appendingPathComponent(fileName)
                try fileManager.moveItem(at: source, to: destination)
                restoredFiles.append(destination)
            }
            try fileManager.removeItem(at: sourceDirectory)
        } catch {
            for restoredURL in restoredFiles.reversed() {
                try? fileManager.moveItem(
                    at: restoredURL,
                    to: sourceDirectory.appendingPathComponent(restoredURL.lastPathComponent)
                )
            }
            throw error
        }
    }

    func loadTitleOverride(sessionID: String, root: URL) -> String? {
        let url = titleOverrideURL(sessionID: sessionID, root: root)
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func titleOverrideURL(sessionID: String, root: URL) -> URL {
        root.appendingPathComponent(sessionID).appendingPathExtension("title.txt")
    }

    private func recentlyDeletedDirectory(root: URL) -> URL {
        root.appendingPathComponent(".RecentlyDeleted", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var sessionManagement: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var sessionManagement: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
