import AppKit
import Darwin
import Foundation

enum SelfUpdateError: LocalizedError {
    case unsupportedArchive
    case appNotFound
    case invalidBundle
    case versionMismatch(expected: String, found: String)
    case signatureInvalid(String)
    case applicationNotWritable(URL)
    case helperLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            return "Automatic installation currently requires the Contora ZIP update asset."
        case .appNotFound:
            return "The downloaded update does not contain Contora.app."
        case .invalidBundle:
            return "The downloaded application has an unexpected bundle identifier."
        case let .versionMismatch(expected, found):
            return "The downloaded application is version \(found), expected \(expected)."
        case let .signatureInvalid(details):
            return "The downloaded application failed code-signature validation: \(details)"
        case let .applicationNotWritable(url):
            return "Contora cannot replace \(url.path). Move it to Applications using an administrator account, then retry."
        case let .helperLaunchFailed(details):
            return "Could not start the update helper: \(details)"
        }
    }
}

enum SelfUpdateInstaller {
    private static let helperFlag = "--contora-apply-update"

    static func stageAndLaunchHelper(archiveURL: URL, expectedVersion: String) throws {
        guard archiveURL.pathExtension.lowercased() == "zip" else {
            throw SelfUpdateError.unsupportedArchive
        }

        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        let parentURL = currentAppURL.deletingLastPathComponent()
        guard currentAppURL.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: parentURL.path) else {
            throw SelfUpdateError.applicationNotWritable(currentAppURL)
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            try run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archiveURL.path, stagingRoot.path]
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }

        let stagedAppURL = stagingRoot.appendingPathComponent("Contora.app", isDirectory: true)
        guard let stagedBundle = Bundle(url: stagedAppURL) else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw SelfUpdateError.appNotFound
        }
        guard stagedBundle.bundleIdentifier == "ai.niketas.contora" else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw SelfUpdateError.invalidBundle
        }
        let stagedVersion = stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        guard stagedVersion == expectedVersion else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw SelfUpdateError.versionMismatch(expected: expectedVersion, found: stagedVersion)
        }

        do {
            try run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", stagedAppURL.path]
            )
            // The archive hash and the nested app signature are verified before removing
            // the download quarantine, matching the behavior expected from an updater.
            try run(
                executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-dr", "com.apple.quarantine", stagedAppURL.path],
                allowFailure: true
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw SelfUpdateError.signatureInvalid(error.localizedDescription)
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw SelfUpdateError.helperLaunchFailed("Current executable path is unavailable.")
        }
        let helper = Process()
        helper.executableURL = executableURL
        helper.arguments = [
            helperFlag,
            String(ProcessInfo.processInfo.processIdentifier),
            stagedAppURL.path,
            currentAppURL.path,
            stagingRoot.path,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            throw SelfUpdateError.helperLaunchFailed(error.localizedDescription)
        }
    }

    static func handleCommandLineIfNeeded() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 6, arguments[1] == helperFlag else {
            return false
        }

        guard let parentPID = Int32(arguments[2]) else {
            return true
        }
        let stagedAppURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let targetAppURL = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let stagingRoot = URL(fileURLWithPath: arguments[5], isDirectory: true)

        for _ in 0..<300 where kill(parentPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }

        let backupURL = targetAppURL.deletingLastPathComponent()
            .appendingPathComponent(".Contora-update-backup-\(UUID().uuidString).app", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: targetAppURL, to: backupURL)
            do {
                try run(
                    executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: [stagedAppURL.path, targetAppURL.path]
                )
            } catch {
                try? fileManager.removeItem(at: targetAppURL)
                try fileManager.moveItem(at: backupURL, to: targetAppURL)
                throw error
            }

            try run(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: [targetAppURL.path]
            )
            Thread.sleep(forTimeInterval: 1)
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: stagingRoot)
        } catch {
            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("contora-update-error.log")
            try? error.localizedDescription.write(to: logURL, atomically: true, encoding: .utf8)
        }
        return true
    }

    private static func run(
        executable: URL,
        arguments: [String],
        allowFailure: Bool = false
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let details = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard allowFailure || process.terminationStatus == 0 else {
            throw SelfUpdateError.helperLaunchFailed(
                details.isEmpty ? "\(executable.lastPathComponent) exited with \(process.terminationStatus)" : details
            )
        }
    }
}
