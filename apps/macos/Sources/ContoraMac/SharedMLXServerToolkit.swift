import Foundation

struct SharedMLXServerToolkit {
    let baseURL: URL
    let startScriptURL: URL
    let stopScriptURL: URL
    let checkScriptURL: URL
    let logFileURL: URL

    static func discover() -> SharedMLXServerToolkit? {
        let env = ProcessInfo.processInfo.environment
        let candidates: [String] = [
            env["NIKETAS_SHARED_MLX_ROOT"] ?? "",
            "/Users/n.likhachev/Documents/projects/test-dmg/shared-mlx",
            "\(NSHomeDirectory())/Documents/projects/test-dmg/shared-mlx"
        ].filter { !$0.isEmpty }

        let fm = FileManager.default
        for path in candidates {
            let baseURL = URL(fileURLWithPath: path, isDirectory: true)
            let startScriptURL = baseURL.appendingPathComponent("bin/start-mlx-server.sh")
            let stopScriptURL = baseURL.appendingPathComponent("bin/stop-mlx-server.sh")
            let checkScriptURL = baseURL.appendingPathComponent("bin/check-mlx.sh")
            let logFileURL = baseURL.appendingPathComponent("mlx-server.log")

            if fm.isExecutableFile(atPath: startScriptURL.path) && fm.fileExists(atPath: checkScriptURL.path) {
                return SharedMLXServerToolkit(
                    baseURL: baseURL,
                    startScriptURL: startScriptURL,
                    stopScriptURL: stopScriptURL,
                    checkScriptURL: checkScriptURL,
                    logFileURL: logFileURL
                )
            }
        }

        return nil
    }
}

enum SharedMLXServerToolkitError: LocalizedError {
    case toolkitNotFound
    case scriptFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .toolkitNotFound:
            return "Shared MLX toolkit was not found on this Mac."
        case let .scriptFailed(message):
            return "Shared MLX toolkit script failed: \(message)"
        }
    }
}

final class SharedMLXServerToolkitService {
    func discoverToolkit() -> SharedMLXServerToolkit? {
        SharedMLXServerToolkit.discover()
    }

    func runScript(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = []

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SharedMLXServerToolkitError.scriptFailed(message: error.localizedDescription)
        }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = [stdout, stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SharedMLXServerToolkitError.scriptFailed(message: message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }

        return [stdout, stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
