// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ContoraMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ContoraMac", targets: ["ContoraMac"]),
    ],
    targets: [
        .executableTarget(
            name: "ContoraMac",
            path: "Sources/ContoraMac",
            exclude: ["Resources"]
        ),
    ]
)
