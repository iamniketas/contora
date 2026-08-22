import Foundation

@main
struct AudioHandoffPathSmokeTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-audio-handoff-path-\(UUID().uuidString)", isDirectory: true)
        let token = "0123456789abcdef0123456789abcdef"
        let paths = MLXAudioHandoffPaths(directory: root, capabilityToken: token)

        guard paths.audioURL.lastPathComponent == "\(token).wav",
              paths.descriptorURL.lastPathComponent == "\(token).json",
              !paths.audioURL.lastPathComponent.contains("(token)"),
              !paths.descriptorURL.lastPathComponent.contains("(token)") else {
            throw SmokeTestError.invalidCapabilityArtifactNames
        }

        print("Audio handoff path smoke test passed")
    }
}

enum SmokeTestError: Error {
    case invalidCapabilityArtifactNames
}
