import Foundation

struct TranscriptionProgress: Decodable, Sendable {
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
