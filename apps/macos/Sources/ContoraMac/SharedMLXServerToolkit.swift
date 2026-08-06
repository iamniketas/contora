import Darwin
import Foundation

struct MLXRuntimeStatus {
    let isInstalled: Bool
    let rootURL: URL
    let pythonURL: URL
    let serverScriptURL: URL
    let logURL: URL

    var displayText: String {
        isInstalled ? "Installed" : "Not installed"
    }
}

enum MLXRuntimeError: LocalizedError {
    case unsupportedArchitecture
    case basePythonMissing
    case artifactMissing
    case invalidArtifact
    case serverNotInstalled
    case serverFailed(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "MLX requires an Apple Silicon Mac."
        case .basePythonMissing:
            return "The shared Python runtime is missing. Run Set Up MLX again to install it."
        case .artifactMissing:
            return "The Contora MLX runtime could not be downloaded from the latest release."
        case .invalidArtifact:
            return "The downloaded MLX runtime archive is incomplete or invalid."
        case .serverNotInstalled:
            return "MLX is not installed. Click Set Up MLX first."
        case let .serverFailed(message):
            return "MLX server failed: \(message)"
        case .portInUse:
            return "Port 8010 is already used by another process. Stop that process and retry."
        }
    }
}

final class SharedMLXServerToolkitService: @unchecked Sendable {
    private let lock = NSLock()
    private var managedProcess: Process?

    func status() -> MLXRuntimeStatus {
        let root = SharedRuntimePaths.mlxAudioRoot()
        let python = SharedRuntimePaths.whisperBundledPython()
        let script = SharedRuntimePaths.mlxServerScript()
        let sitePackages = SharedRuntimePaths.mlxVenvSitePackages()
        let mlxAudio = sitePackages.appendingPathComponent("mlx_audio", isDirectory: true)
        let mlxCore = sitePackages.appendingPathComponent("mlx", isDirectory: true)
        let installed = FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: script.path)
            && FileManager.default.fileExists(atPath: mlxAudio.path)
            && FileManager.default.fileExists(atPath: mlxCore.path)
        return MLXRuntimeStatus(
            isInstalled: installed,
            rootURL: root,
            pythonURL: python,
            serverScriptURL: script,
            logURL: SharedRuntimePaths.mlxServerLog()
        )
    }

    func install(onProgress: @escaping @Sendable (String) -> Void) async throws -> MLXRuntimeStatus {
        #if !arch(arm64)
        throw MLXRuntimeError.unsupportedArchitecture
        #endif

        guard FileManager.default.isExecutableFile(atPath: SharedRuntimePaths.whisperBundledPython().path) else {
            throw MLXRuntimeError.basePythonMissing
        }

        let artifactURL = configuredArtifactURL()
        onProgress("Downloading MLX runtime…")
        let (downloadedURL, response) = try await URLSession.shared.download(from: artifactURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MLXRuntimeError.artifactMissing
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-mlx-install-\(UUID().uuidString)", isDirectory: true)
        let extractDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)
        let archiveURL = temporaryDirectory.appendingPathComponent("runtime.tar.gz")
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

        onProgress("Extracting MLX runtime…")
        try runAndLog(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", extractDirectory.path],
            logURL: temporaryDirectory.appendingPathComponent("extract.log")
        )

        guard let extractedRoot = findExtractedRoot(in: extractDirectory) else {
            throw MLXRuntimeError.invalidArtifact
        }

        onProgress("Installing MLX runtime…")
        try installExtractedRoot(extractedRoot)
        try refreshServerScriptFromApp()
        onProgress("MLX runtime installed")
        return status()
    }

    func start(modelID: String) async throws -> String {
        guard status().isInstalled else {
            throw MLXRuntimeError.serverNotInstalled
        }
        if await isHealthy() {
            return "MLX server is ready"
        }
        if await isPortOccupied() {
            throw MLXRuntimeError.portInUse
        }

        try stopManagedProcess()
        try refreshServerScriptFromApp()

        let runtime = status()
        try FileManager.default.createDirectory(at: runtime.rootURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runtime.logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: runtime.logURL)
        try logHandle.seekToEnd()
        try logHandle.write(contentsOf: "[Contora] Starting MLX server with \(modelID)\n".data(using: .utf8)!)

        let process = Process()
        process.executableURL = runtime.pythonURL
        process.arguments = [runtime.serverScriptURL.path]
        process.currentDirectoryURL = runtime.rootURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        var environment = ProcessInfo.processInfo.environment
        let pythonHome = runtime.pythonURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedWhisperSitePackages = SharedRuntimePaths.whisperRoot()
            .appendingPathComponent("venv/lib/python3.12/site-packages", isDirectory: true)
        environment["PYTHONHOME"] = pythonHome.path
        environment["PYTHONPATH"] = [
            SharedRuntimePaths.mlxVenvSitePackages().path,
            sharedWhisperSitePackages.path,
        ].joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["CONTORA_WHISPER_RUNTIME_ROOT"] = SharedRuntimePaths.whisperRoot().path
        environment["CONTORA_MLX_MODEL"] = modelID
        environment["CONTORA_MLX_HOST"] = "127.0.0.1"
        environment["CONTORA_MLX_PORT"] = "8010"
        environment["HF_HUB_DISABLE_XET"] = "1"
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw MLXRuntimeError.serverFailed(error.localizedDescription)
        }

        lock.withLock { managedProcess = process }
        try String(process.processIdentifier).write(
            to: SharedRuntimePaths.mlxServerPIDFile(),
            atomically: true,
            encoding: .utf8
        )

        for _ in 0..<120 {
            if await isHealthy() {
                return "MLX server is ready on 127.0.0.1:8010"
            }
            if !process.isRunning {
                let details = logTail()
                throw MLXRuntimeError.serverFailed(details.isEmpty ? "process exited during startup" : details)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        try? stopManagedProcess()
        throw MLXRuntimeError.serverFailed("startup timed out. Open the MLX log for details.")
    }

    func stop() throws -> String {
        try stopManagedProcess()
        return "MLX server stopped"
    }

    func check() async -> String {
        guard status().isInstalled else {
            return "MLX runtime is not installed"
        }
        if await isHealthy() {
            return "MLX server is ready on 127.0.0.1:8010"
        }
        return "MLX runtime is installed, but the server is stopped"
    }

    func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8010/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    func logTail() -> String {
        guard let text = try? String(contentsOf: SharedRuntimePaths.mlxServerLog(), encoding: .utf8) else {
            return ""
        }
        return String(text.suffix(6_000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configuredArtifactURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTORA_MACOS_MLX_RUNTIME_URL"],
           let url = URL(string: override), !override.isEmpty {
            return url
        }
        return URL(string: "https://github.com/iamniketas/contora/releases/latest/download/ContoraMacMLXRuntime-arm64.tar.gz")!
    }

    private func findExtractedRoot(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("mlx-audio", isDirectory: true)
        if validateExtractedRoot(direct) { return direct }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "mlx-audio" {
            if validateExtractedRoot(url) { return url }
        }
        return nil
    }

    private func validateExtractedRoot(_ root: URL) -> Bool {
        let sitePackages = root.appendingPathComponent("venv/lib/python3.12/site-packages", isDirectory: true)
        return FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("mlx_audio").path)
            && FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("mlx").path)
    }

    private func installExtractedRoot(_ source: URL) throws {
        let destination = SharedRuntimePaths.mlxAudioRoot()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try runAndLog(
            executable: URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["-R", "u+rwX", destination.path],
            logURL: destination.appendingPathComponent("install.log")
        )
    }

    private func refreshServerScriptFromApp() throws {
        let resourceName = "contora_mlx_server.py"
        let packageBundleName = "ContoraMac_ContoraMac.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            Bundle.main.bundleURL.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            executableDirectory.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
        ].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }
        let destination = SharedRuntimePaths.mlxServerScript()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private func isPortOccupied() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:8010", "-sTCP:LISTEN"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func stopManagedProcess() throws {
        if let process = lock.withLock({ managedProcess }), process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        lock.withLock { managedProcess = nil }

        let pidFile = SharedRuntimePaths.mlxServerPIDFile()
        if let value = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1,
           commandForPID(pid).contains("contora_mlx_server.py") {
            _ = Darwin.kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func commandForPID(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func runAndLog(executable: URL, arguments: [String], logURL: URL) throws {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            process.waitUntilExit()
            try? handle.close()
        } catch {
            try? handle.close()
            throw MLXRuntimeError.serverFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw MLXRuntimeError.serverFailed(details.isEmpty ? "exit \(process.terminationStatus)" : details)
        }
    }
}
