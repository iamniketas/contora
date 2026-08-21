import Darwin
import Foundation

enum FasterWhisperProcessError: LocalizedError {
    case executableNotFound(URL)
    case inputAudioNotFound(URL)
    case processFailed(code: Int32, details: String)
    case outputNotFound(URL)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "faster-whisper executable not found at \(path.path)"
        case let .inputAudioNotFound(path):
            return "Input audio file not found at \(path.path)"
        case let .processFailed(code, details):
            return "faster-whisper failed with code \(code): \(details)"
        case let .outputNotFound(path):
            return "Expected transcription output was not found at \(path.path)"
        }
    }
}

struct FasterWhisperProcessProgress: Decodable, Sendable {
    let phase: String
    let progress: Double
    let message: String
    let currentSeconds: Double?
    let totalSeconds: Double?
    let etaSeconds: Double?

    var fraction: Double {
        min(1, max(0, progress))
    }
}

final class FasterWhisperCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }
}

private final class FasterWhisperLogWriter: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private let handle: FileHandle

    init() throws {
        let directory = SharedRuntimePaths.whisperLogsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeOldLogs(in: directory)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        url = directory.appendingPathComponent("local-whisper-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lock.withLock {
            try? handle.write(contentsOf: data)
        }
    }

    func close() {
        lock.withLock {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private static func removeOldLogs(in directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files
            .filter { $0.lastPathComponent.hasPrefix("local-whisper-") && $0.pathExtension == "log" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for oldLog in sorted.dropFirst(10) {
            try? FileManager.default.removeItem(at: oldLog)
        }
    }
}

private final class FasterWhisperStreamCollector: @unchecked Sendable {
    private static let progressPrefix = "CONTORA_PROGRESS "

    private let streamName: String
    private let logWriter: FasterWhisperLogWriter
    private let onProgress: @Sendable (FasterWhisperProcessProgress) -> Void
    private let lock = NSLock()
    private var pending = Data()
    private var tail = ""

    init(
        streamName: String,
        logWriter: FasterWhisperLogWriter,
        onProgress: @escaping @Sendable (FasterWhisperProcessProgress) -> Void
    ) {
        self.streamName = streamName
        self.logWriter = logWriter
        self.onProgress = onProgress
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            pending.append(data)
            var result: [String] = []
            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newlineIndex]
                pending.removeSubrange(...newlineIndex)
                result.append(String(decoding: lineData, as: UTF8.self))
            }
            return result
        }
        lines.forEach(handleLine)
    }

    func finish() {
        let remainder: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll(keepingCapacity: false) }
            return String(decoding: pending, as: UTF8.self)
        }
        if let remainder, !remainder.isEmpty {
            handleLine(remainder)
        }
    }

    func tailText() -> String {
        lock.withLock { tail }
    }

    private func handleLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        logWriter.append("[\(streamName)] \(line)\n")

        lock.withLock {
            tail += line + "\n"
            if tail.count > 16_000 {
                tail = String(tail.suffix(16_000))
            }
        }

        guard streamName == "stdout", line.hasPrefix(Self.progressPrefix) else { return }
        let payload = String(line.dropFirst(Self.progressPrefix.count))
        guard let data = payload.data(using: .utf8),
              let progress = try? JSONDecoder().decode(FasterWhisperProcessProgress.self, from: data) else {
            logWriter.append("[contora] Could not decode progress event\n")
            return
        }
        onProgress(progress)
    }
}

struct FasterWhisperProcessTranscriptionService {
    var executableURL: URL = SharedRuntimePaths.whisperExecutable()
    var modelName: String = "large-v2"
    var language: String = "ru"
    var enableDiarization = true

    func transcribe(
        audioFileURL: URL,
        outputDirectory: URL,
        onProgress: @escaping @Sendable (FasterWhisperProcessProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        let fm = FileManager.default

        guard fm.fileExists(atPath: executableURL.path) else {
            throw FasterWhisperProcessError.executableNotFound(executableURL)
        }

        guard fm.fileExists(atPath: audioFileURL.path) else {
            throw FasterWhisperProcessError.inputAudioNotFound(audioFileURL)
        }

        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try refreshRuntimeTranscribeScriptIfAvailable()

        let outputBaseName = audioFileURL.deletingPathExtension().lastPathComponent
        let expectedOutput = outputDirectory.appendingPathComponent("\(outputBaseName).txt")
        let logWriter = try FasterWhisperLogWriter()
        logWriter.append("[contora] Started \(ISO8601DateFormatter().string(from: Date()))\n")
        logWriter.append("[contora] Executable: \(executableURL.path)\n")
        logWriter.append("[contora] Model: \(modelName); language: \(language); diarization: \(enableDiarization)\n")
        defer { logWriter.close() }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = makeArguments(audioFileURL: audioFileURL, outputDirectory: outputDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["CONTORA_WHISPER_RUNTIME_ROOT"] = SharedRuntimePaths.whisperRoot().path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = FasterWhisperStreamCollector(
            streamName: "stdout",
            logWriter: logWriter,
            onProgress: onProgress
        )
        let errorCollector = FasterWhisperStreamCollector(
            streamName: "stderr",
            logWriter: logWriter,
            onProgress: onProgress
        )
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.consume(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.consume(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        var cancellationStartedAt: Date?
        while process.isRunning {
            if isCancelled() {
                if cancellationStartedAt == nil {
                    cancellationStartedAt = Date()
                    logWriter.append("[contora] Cancellation requested\n")
                    process.terminate()
                } else if Date().timeIntervalSince(cancellationStartedAt!) > 2 {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputCollector.consume(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorCollector.consume(errorPipe.fileHandleForReading.readDataToEndOfFile())
        outputCollector.finish()
        errorCollector.finish()

        if cancellationStartedAt != nil || isCancelled() {
            throw CancellationError()
        }

        if process.terminationStatus != 0 {
            let details = [errorCollector.tailText(), outputCollector.tailText()]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = details.isEmpty ? "No process output. Log: \(logWriter.url.path)" : "\(details)\nLog: \(logWriter.url.path)"
            throw FasterWhisperProcessError.processFailed(code: process.terminationStatus, details: message)
        }

        guard fm.fileExists(atPath: expectedOutput.path) else {
            throw FasterWhisperProcessError.outputNotFound(expectedOutput)
        }

        return try String(contentsOf: expectedOutput, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshRuntimeTranscribeScriptIfAvailable() throws {
        guard executableURL.standardizedFileURL == SharedRuntimePaths.whisperExecutable().standardizedFileURL else {
            return
        }

        let resourceName = "contora_fw_transcribe.py"
        let packageBundleName = "ContoraMac_ContoraMac.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            Bundle.main.bundleURL.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            executableDirectory.appendingPathComponent("\(packageBundleName)/Resources/\(resourceName)"),
            Bundle.main.resourceURL?.appendingPathComponent("\(resourceName)"),
        ].compactMap { $0 }

        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }

        let destination = SharedRuntimePaths.whisperTranscribeScript()
        let sourceData = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == sourceData {
            return
        }
        try sourceData.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private func makeArguments(audioFileURL: URL, outputDirectory: URL) -> [String] {
        var arguments = [
            "-pp",
            "-o", outputDirectory.path,
            "--standard",
            "-f", "txt",
            "-m", modelName,
            "--language", language,
        ]

        let modelsRoot = SharedRuntimePaths.modelsDirectory()
        if FileManager.default.fileExists(atPath: modelsRoot.path) {
            arguments.append(contentsOf: ["--model_dir", modelsRoot.path])
        }

        if enableDiarization {
            arguments.append(contentsOf: ["--diarize", "pyannote_v3.1"])
        }

        arguments.append(audioFileURL.path)
        return arguments
    }
}
