import Darwin
import CryptoKit
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
    case artifactMissing
    case invalidArtifact
    case serverNotInstalled
    case serverFailed(String)
    case portInUse
    case serverBusy

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "MLX requires an Apple Silicon Mac."
        case .artifactMissing:
            return "The Contora speech runtime could not be downloaded from the latest release."
        case .invalidArtifact:
            return "The downloaded speech runtime archive is incomplete or invalid."
        case .serverNotInstalled:
            return "The speech runtime is not installed. Click Set Up Speech Runtime first."
        case let .serverFailed(message):
            return "MLX server failed: \(message)"
        case .portInUse:
            return "Port 8010 is already used by another process. Stop that process and retry."
        case .serverBusy:
            return "The managed speech backend has an active transcription job. Retry after it finishes."
        }
    }
}

final class SharedMLXServerToolkitService: @unchecked Sendable {
    private let lock = NSLock()
    private var managedProcess: Process?

    func status() -> MLXRuntimeStatus {
        let root = SharedRuntimePaths.speechRuntimeRoot()
        let python = SharedRuntimePaths.speechRuntimePython()
        let script = SharedRuntimePaths.mlxServerScript()
        let sitePackages = SharedRuntimePaths.mlxVenvSitePackages()
        let mlxAudio = sitePackages.appendingPathComponent("mlx_audio", isDirectory: true)
        let mlxCore = sitePackages.appendingPathComponent("mlx", isDirectory: true)
        let pyannote = sitePackages.appendingPathComponent("pyannote", isDirectory: true)
        let torch = sitePackages.appendingPathComponent("torch", isDirectory: true)
        let diarizationConfig = root.appendingPathComponent("pyannote/speaker-diarization-3.1/config.yaml")
        let segmentationModel = root.appendingPathComponent("pyannote/segmentation-3.0/pytorch_model.bin")
        let embeddingModel = root.appendingPathComponent("pyannote/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin")
        let installed = FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: script.path)
            && FileManager.default.fileExists(atPath: mlxAudio.path)
            && FileManager.default.fileExists(atPath: mlxCore.path)
            && FileManager.default.fileExists(atPath: pyannote.path)
            && FileManager.default.fileExists(atPath: torch.path)
            && FileManager.default.fileExists(atPath: diarizationConfig.path)
            && FileManager.default.fileExists(atPath: segmentationModel.path)
            && FileManager.default.fileExists(atPath: embeddingModel.path)
            && runtimeManifestIsValid(root.appendingPathComponent("runtime-manifest.json"))
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

        let artifactURL = configuredArtifactURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-mlx-install-\(UUID().uuidString)", isDirectory: true)
        let extractDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)
        let archiveURL = temporaryDirectory.appendingPathComponent("runtime.tar.gz")
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        if artifactURL.isFileURL {
            onProgress("Reading bundled speech runtime…")
            guard FileManager.default.fileExists(atPath: artifactURL.path) else {
                throw MLXRuntimeError.artifactMissing
            }
            try FileManager.default.copyItem(at: artifactURL, to: archiveURL)
        } else {
            onProgress("Downloading self-contained speech runtime…")
            let (downloadedURL, response) = try await URLSession.shared.download(from: artifactURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MLXRuntimeError.artifactMissing
            }
            try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)
        }
        onProgress("Verifying speech runtime checksum…")
        try await verifyChecksum(of: archiveURL, sourceURL: artifactURL)
        try validateArchivePaths(archiveURL)

        onProgress("Extracting speech runtime…")
        try runAndLog(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", extractDirectory.path],
            logURL: temporaryDirectory.appendingPathComponent("extract.log")
        )

        guard let extractedRoot = findExtractedRoot(in: extractDirectory) else {
            throw MLXRuntimeError.invalidArtifact
        }

        if await isHealthy(), !(await isIdle()) {
            throw MLXRuntimeError.serverBusy
        }
        onProgress("Stopping the managed backend…")
        try stopManagedProcess()
        onProgress("Installing speech runtime…")
        try installExtractedRoot(extractedRoot)
        _ = try refreshServerFilesFromApp()
        onProgress("Speech runtime installed")
        return status()
    }

    func start(
        modelID: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        guard status().isInstalled else {
            throw MLXRuntimeError.serverNotInstalled
        }
        let serverFilesChanged = try refreshServerFilesFromApp()
        if await isHealthy() {
            if !serverFilesChanged {
                return "MLX server is ready"
            }
            try stopManagedProcess()
        }
        if await isPortOccupied() {
            throw MLXRuntimeError.portInUse
        }

        try stopManagedProcess()
        onProgress("Launching managed speech backend…")

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
        environment["PYTHONHOME"] = pythonHome.path
        environment["PYTHONPATH"] = SharedRuntimePaths.speechRuntimeSitePackages().path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["CONTORA_SPEECH_RUNTIME_ROOT"] = SharedRuntimePaths.speechRuntimeRoot().path
        environment["CONTORA_MLX_MODEL"] = modelID
        environment["CONTORA_MLX_HOST"] = "127.0.0.1"
        environment["CONTORA_MLX_PORT"] = "8010"
        environment["CONTORA_MLX_IDLE_SHUTDOWN_SECONDS"] = "300"
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

        for attempt in 0..<120 {
            if await isHealthy() {
                return "MLX server is ready on 127.0.0.1:8010"
            }
            if !process.isRunning {
                let details = logTail()
                throw MLXRuntimeError.serverFailed(details.isEmpty ? "process exited during startup" : details)
            }
            if attempt > 0, attempt.isMultiple(of: 4) {
                onProgress("Launching managed speech backend (\(attempt / 2)s)…")
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        try? stopManagedProcess()
        throw MLXRuntimeError.serverFailed("startup timed out. Open the MLX log for details.")
    }

    func stop() throws -> String {
        guard serverHasNoActiveJobsBlocking() else {
            return "MLX server left running because another transcription job is active"
        }
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

    func isIdle() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8010/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activeJobs = object["activeJobs"] as? Int else { return false }
            return activeJobs == 0
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
        let environment = ProcessInfo.processInfo.environment
        if let archive = environment["CONTORA_MACOS_SPEECH_RUNTIME_ARCHIVE"], !archive.isEmpty {
            return URL(fileURLWithPath: archive)
        }
        if let override = environment["CONTORA_MACOS_SPEECH_RUNTIME_URL"], !override.isEmpty {
            if let url = URL(string: override), url.scheme != nil {
                return url
            }
            return URL(fileURLWithPath: override)
        }
        let archiveName = "ContoraMacSpeechRuntime-arm64.tar.gz"
        let packageBundleName = "ContoraMac_ContoraMac.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundledCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(archiveName),
            Bundle.main.resourceURL?.appendingPathComponent("\(packageBundleName)/Resources/\(archiveName)"),
            executableDirectory.appendingPathComponent("../Resources/\(archiveName)").standardizedFileURL,
        ].compactMap { $0 }
        if let bundled = bundledCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return bundled
        }
        return URL(string: "https://github.com/iamniketas/contora/releases/latest/download/\(archiveName)")!
    }

    private func verifyChecksum(of archiveURL: URL, sourceURL: URL) async throws {
        let checksumURL = sourceURL.isFileURL
            ? URL(fileURLWithPath: sourceURL.path + ".sha256")
            : URL(string: sourceURL.absoluteString + ".sha256")!
        let checksumData: Data
        if checksumURL.isFileURL {
            guard let data = try? Data(contentsOf: checksumURL) else {
                throw MLXRuntimeError.artifactMissing
            }
            checksumData = data
        } else {
            let (data, response) = try await URLSession.shared.data(from: checksumURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MLXRuntimeError.artifactMissing
            }
            checksumData = data
        }
        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expected = checksumText.split(whereSeparator: { $0.isWhitespace }).first,
              expected.count == 64 else {
            throw MLXRuntimeError.invalidArtifact
        }

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(String(expected)) == .orderedSame else {
            throw MLXRuntimeError.invalidArtifact
        }
    }

    private func validateArchivePaths(_ archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", archiveURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let listing = String(data: data, encoding: .utf8) else {
            throw MLXRuntimeError.invalidArtifact
        }
        let paths = listing.split(separator: "\n").map(String.init)
        guard !paths.isEmpty, paths.allSatisfy({ entry in
            let trimmed = entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            return !entry.hasPrefix("/")
                && components.first == "speech-runtime"
                && !components.contains("..")
        }) else {
            throw MLXRuntimeError.invalidArtifact
        }
    }

    private func findExtractedRoot(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("speech-runtime", isDirectory: true)
        if validateExtractedRoot(direct) { return direct }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "speech-runtime" {
            if validateExtractedRoot(url) { return url }
        }
        return nil
    }

    private func validateExtractedRoot(_ root: URL) -> Bool {
        let sitePackages = root.appendingPathComponent("venv/lib/python3.12/site-packages", isDirectory: true)
        let python = root.appendingPathComponent("python/Python.framework/Versions/3.12/bin/python3.12")
        return FileManager.default.isExecutableFile(atPath: python.path)
            && runtimeManifestIsValid(root.appendingPathComponent("runtime-manifest.json"))
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("pyannote/speaker-diarization-3.1/config.yaml").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("pyannote/segmentation-3.0/pytorch_model.bin").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("pyannote/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin").path)
            && FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("mlx_audio").path)
            && FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("mlx").path)
            && FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("pyannote").path)
            && FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("torch").path)
    }

    private func runtimeManifestIsValid(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["runtimeId"] as? String == "speech-runtime"
            && object["pythonVersion"] as? String == "3.12"
            && object["containsBundledPython"] as? Bool == true
            && object["containsPyannoteAssets"] as? Bool == true
    }

    private func installExtractedRoot(_ source: URL) throws {
        let destination = SharedRuntimePaths.speechRuntimeRoot()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".speech-runtime-install-\(UUID().uuidString)", isDirectory: true)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".speech-runtime-backup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
            try runAndLog(
                executable: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["-R", "u+rwX", destination.path],
                logURL: destination.appendingPathComponent("install.log")
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    @discardableResult
    private func refreshServerFilesFromApp() throws -> Bool {
        let resources: [(name: String, destination: URL, permissions: Int)] = [
            ("contora_mlx_server.py", SharedRuntimePaths.mlxServerScript(), 0o755),
            ("result_safety.py", SharedRuntimePaths.mlxResultSafetyModule(), 0o644),
        ]
        var changed = false
        for resource in resources {
            changed = try installBundledResource(
                named: resource.name,
                at: resource.destination,
                permissions: resource.permissions
            ) || changed
        }
        return changed
    }

    private func installBundledResource(named resourceName: String, at destination: URL, permissions: Int) throws -> Bool {
        let packageBundleName = "ContoraMac_ContoraMac.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            Bundle.main.bundleURL.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            executableDirectory.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
        ].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MLXRuntimeError.artifactMissing
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceData = try Data(contentsOf: source)
        let changed = (try? Data(contentsOf: destination)) != sourceData
        if changed {
            try sourceData.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        return changed
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

    private func serverHasNoActiveJobsBlocking() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fsS", "--max-time", "1", "http://127.0.0.1:8010/health"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return true
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activeJobs = object["activeJobs"] as? Int else {
                return false
            }
            return activeJobs == 0
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
