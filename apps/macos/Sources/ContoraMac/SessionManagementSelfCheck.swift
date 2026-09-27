import Foundation

#if DEBUG
enum SessionManagementSelfCheck {
    enum CheckError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): return message
            }
        }
    }

    static func run() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ContoraSessionManagementCheck-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = SessionManagementService(rootURLProvider: { root })
        let sessionID = "import-check-session"
        let manifestURL = root.appendingPathComponent(sessionID).appendingPathExtension("session.json")
        let transcriptURL = root.appendingPathComponent(sessionID).appendingPathExtension("txt")
        let externalURL = root.appendingPathComponent("external-source.m4a")
        let manifest: [String: Any] = [
            "sessionID": sessionID,
            "title": "Old title",
            "updatedAt": "2026-01-01T00:00:00Z",
            "futureMetadata": ["mustSurvive": true],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try Data("transcript".utf8).write(to: transcriptURL)
        try Data("external".utf8).write(to: externalURL)

        try service.renameSession(id: sessionID, to: "  Weekly planning\n")
        let renamedData = try Data(contentsOf: manifestURL)
        guard let renamed = try JSONSerialization.jsonObject(with: renamedData) as? [String: Any],
              renamed["title"] as? String == "Weekly planning",
              (renamed["futureMetadata"] as? [String: Any])?["mustSurvive"] as? Bool == true else {
            throw CheckError.failed("Rename did not preserve manifest metadata")
        }

        try service.moveToRecentlyDeleted(sessionID: sessionID, title: "Weekly planning")
        guard !fileManager.fileExists(atPath: manifestURL.path),
              !fileManager.fileExists(atPath: transcriptURL.path),
              fileManager.fileExists(atPath: externalURL.path) else {
            throw CheckError.failed("Move to Recently Deleted touched the wrong files")
        }

        let deleted = try service.loadRecentlyDeleted()
        guard deleted.count == 1, deleted[0].id == sessionID else {
            throw CheckError.failed("Recently Deleted metadata was not loaded")
        }
        try service.restore(deleted[0])
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: transcriptURL.path),
              fileManager.fileExists(atPath: externalURL.path),
              try service.loadRecentlyDeleted().isEmpty else {
            throw CheckError.failed("Restore did not return the complete session")
        }
    }
}
#endif
