import Foundation

enum PCMFloatScratchFileBufferError: LocalizedError {
    case createFailed
    case readFailed

    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "Failed to create scratch audio buffer."
        case .readFailed:
            return "Failed to read scratch audio buffer."
        }
    }
}

final class PCMFloatScratchFileBuffer {
    private let fileManager = FileManager.default
    private(set) var url: URL
    private var handle: FileHandle
    private(set) var sampleCount = 0

    init(prefix: String) throws {
        let directory = fileManager.temporaryDirectory
        url = directory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("pcm32")

        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw PCMFloatScratchFileBufferError.createFailed
        }

        handle = try FileHandle(forWritingTo: url)
    }

    func append(samples: [Float]) throws {
        guard !samples.isEmpty else {
            return
        }

        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for value in samples {
            var bitPattern = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func finishReadingAllSamples() throws -> [Float] {
        try handle.close()
        let data = try Data(contentsOf: url)
        defer { try? fileManager.removeItem(at: url) }

        guard data.count % MemoryLayout<UInt32>.size == 0 else {
            throw PCMFloatScratchFileBufferError.readFailed
        }

        let sampleCount = data.count / MemoryLayout<UInt32>.size
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let uintBuffer = rawBuffer.bindMemory(to: UInt32.self)
            for value in uintBuffer {
                samples.append(Float(bitPattern: UInt32(littleEndian: value)))
            }
        }
        return samples
    }

    func discard() {
        try? handle.close()
        try? fileManager.removeItem(at: url)
    }
}
