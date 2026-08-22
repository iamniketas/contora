// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ContoraTranscriptionBenchmarkNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "contora-fluid-diarize", targets: ["ContoraFluidDiarize"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "ContoraFluidDiarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
