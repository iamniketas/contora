import Foundation

@main
struct UpdatedAppMarker {
    static func main() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-self-update-smoke-passed")
        try "updated".write(to: markerURL, atomically: true, encoding: .utf8)
    }
}
