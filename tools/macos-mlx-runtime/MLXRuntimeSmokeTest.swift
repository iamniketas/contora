import Foundation

@main
struct MLXRuntimeSmokeTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeTestError.audioPathMissing
        }

        let service = SharedMLXServerToolkitService()
        _ = try await service.install { message in
            print(message)
        }
        print(try await service.start(modelID: "mlx-community/whisper-large-v3-turbo-asr-fp16"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-fsS",
            "http://127.0.0.1:8010/v1/audio/transcriptions",
            "-F", "file=@\(CommandLine.arguments[1])",
            "-F", "model=mlx-community/whisper-large-v3-turbo-asr-fp16",
            "-F", "language=en",
            "-F", "diarize=false",
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        _ = try service.stop()

        guard process.terminationStatus == 0, stdout.contains("\"text\"") else {
            throw SmokeTestError.transcriptionFailed(stderr.isEmpty ? stdout : stderr)
        }
        print(stdout)
        print("MLX runtime smoke test passed")
    }
}

enum SmokeTestError: Error {
    case audioPathMissing
    case transcriptionFailed(String)
}
