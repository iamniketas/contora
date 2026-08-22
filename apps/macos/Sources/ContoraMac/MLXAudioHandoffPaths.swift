import Foundation

struct MLXAudioHandoffPaths: Equatable, Sendable {
    let audioURL: URL
    let descriptorURL: URL

    init(directory: URL, capabilityToken: String) {
        audioURL = directory.appendingPathComponent("\(capabilityToken).wav")
        descriptorURL = directory.appendingPathComponent("\(capabilityToken).json")
    }
}
