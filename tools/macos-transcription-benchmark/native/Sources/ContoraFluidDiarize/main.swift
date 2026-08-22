import FluidAudio
import Foundation

private struct Arguments {
    let audio: URL
    let output: URL
    let models: URL
    let threshold: Double
    let modelRevision: String

    init(_ values: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count else {
                throw BenchmarkError.invalidArguments("Expected --key value, got \(key)")
            }
            options[key] = values[index + 1]
            index += 2
        }
        guard let audio = options["--audio"],
              let output = options["--output"],
              let models = options["--models"],
              let modelRevision = options["--model-revision"]
        else {
            throw BenchmarkError.invalidArguments(
                "Required: --audio PATH --output PATH --models PATH --model-revision SHA"
            )
        }
        self.audio = URL(fileURLWithPath: audio)
        self.output = URL(fileURLWithPath: output)
        self.models = URL(fileURLWithPath: models, isDirectory: true)
        self.threshold = Double(options["--threshold"] ?? "0.7045655") ?? 0.7045655
        self.modelRevision = modelRevision
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments(String)
    case invalidModelSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .invalidModelSnapshot(let message): message
        }
    }
}

private func validatePinnedModels(root: URL, revision: String) throws {
    let repository = root.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
    let marker = repository.appendingPathComponent(".contora-model-revision")
    let recordedRevision = try String(contentsOf: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard recordedRevision == revision else {
        throw BenchmarkError.invalidModelSnapshot(
            "Expected model revision \(revision), found \(recordedRevision)"
        )
    }
    let required = [
        "Segmentation.mlmodelc/coremldata.bin",
        "FBank.mlmodelc/coremldata.bin",
        "Embedding.mlmodelc/coremldata.bin",
        "PldaRho.mlmodelc/coremldata.bin",
        "plda-parameters.json",
    ]
    for relativePath in required {
        let url = repository.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkError.invalidModelSnapshot("Missing pinned model asset: \(relativePath)")
        }
    }
}

private struct Engine: Encodable {
    let id = "fluidaudio-offline"
    let version = "0.9.1"
    let model = "FluidInference/speaker-diarization-coreml"
    let modelRevision: String
    let threshold: Double
}

private struct SpeakerTurn: Encodable {
    let start: Double
    let end: Double
    let speaker: String
    let confidence: Double?
}

private struct Timing: Encodable {
    let modelLoadingSeconds: Double
    let audioLoadingSeconds: Double
    let inferenceSeconds: Double
    let totalSeconds: Double
    let upstream: PipelineTimings?
}

private struct Prediction: Encodable {
    let schemaVersion = "1.0"
    let kind = "diarization"
    let engine: Engine
    let text = ""
    let segments: [String] = []
    let words: [String] = []
    let speakerTurns: [SpeakerTurn]
    let timing: Timing

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind, engine, text, segments, words
        case speakerTurns = "speaker_turns"
        case timing
    }
}

@main
private enum ContoraFluidDiarize {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            try validatePinnedModels(root: arguments.models, revision: arguments.modelRevision)
            let totalStarted = Date()
            let configuration = OfflineDiarizerConfig(clusteringThreshold: arguments.threshold)
            let manager = OfflineDiarizerManager(config: configuration)

            let modelStarted = Date()
            let models = try await OfflineDiarizerModels.load(from: arguments.models)
            manager.initialize(models: models)
            let modelLoading = Date().timeIntervalSince(modelStarted)

            let factory = StreamingAudioSourceFactory()
            let prepared = try factory.makeDiskBackedSource(
                from: arguments.audio,
                targetSampleRate: configuration.segmentation.sampleRate
            )
            defer { prepared.source.cleanup() }

            let inferenceStarted = Date()
            let result = try await manager.process(
                audioSource: prepared.source,
                audioLoadingSeconds: prepared.loadDuration
            )
            try validatePinnedModels(root: arguments.models, revision: arguments.modelRevision)
            let inference = Date().timeIntervalSince(inferenceStarted)
            let turns = result.segments.map {
                SpeakerTurn(
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds),
                    speaker: $0.speakerId,
                    confidence: Double($0.qualityScore)
                )
            }
            let prediction = Prediction(
                engine: Engine(
                    modelRevision: arguments.modelRevision,
                    threshold: arguments.threshold
                ),
                speakerTurns: turns,
                timing: Timing(
                    modelLoadingSeconds: modelLoading,
                    audioLoadingSeconds: prepared.loadDuration,
                    inferenceSeconds: inference,
                    totalSeconds: Date().timeIntervalSince(totalStarted),
                    upstream: result.timings
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(prediction)
            try FileManager.default.createDirectory(
                at: arguments.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: arguments.output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("FluidAudio adapter failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(2)
        }
    }
}
