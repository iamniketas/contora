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

struct FasterWhisperProcessTranscriptionService {
    var executableURL: URL = SharedRuntimePaths.whisperExecutable()
    var modelName: String = "large-v2"
    var language: String = "ru"

    func transcribe(audioFileURL: URL, outputDirectory: URL) throws -> String {
        let fm = FileManager.default

        guard fm.fileExists(atPath: executableURL.path) else {
            throw FasterWhisperProcessError.executableNotFound(executableURL)
        }

        guard fm.fileExists(atPath: audioFileURL.path) else {
            throw FasterWhisperProcessError.inputAudioNotFound(audioFileURL)
        }

        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let outputBaseName = audioFileURL.deletingPathExtension().lastPathComponent
        let expectedOutput = outputDirectory.appendingPathComponent("\(outputBaseName).txt")

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = [
            "--model", modelName,
            "--language", language,
            "--task", "transcribe",
            "--output_format", "txt",
            "--output_dir", outputDirectory.path,
            audioFileURL.path,
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let details = readText(pipe: errorPipe) + "\n" + readText(pipe: outputPipe)
            throw FasterWhisperProcessError.processFailed(code: process.terminationStatus, details: details)
        }

        guard fm.fileExists(atPath: expectedOutput.path) else {
            throw FasterWhisperProcessError.outputNotFound(expectedOutput)
        }

        return try String(contentsOf: expectedOutput, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readText(pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
