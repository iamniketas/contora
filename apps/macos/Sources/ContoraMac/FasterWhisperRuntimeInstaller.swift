import Foundation

enum FasterWhisperRuntimeInstallError: LocalizedError {
    case pythonNotFound
    case commandFailed(String)
    case artifactNotFound
    case artifactInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python 3 was not found. Install Python 3 first, then retry."
        case let .commandFailed(message):
            return message
        case .artifactNotFound:
            return "Contora macOS Whisper runtime artifact was not configured."
        case let .artifactInstallFailed(message):
            return message
        }
    }
}

struct FasterWhisperRuntimeStatus {
    let isInstalled: Bool
    let executableURL: URL
    let pythonURL: URL
    let bundledPythonURL: URL
    let scriptURL: URL

    var displayText: String {
        isInstalled ? "Installed at \(executableURL.path)" : "Missing at \(executableURL.path)"
    }
}

final class FasterWhisperRuntimeInstaller {
    func status() -> FasterWhisperRuntimeStatus {
        let executableURL = SharedRuntimePaths.whisperExecutable()
        let pythonURL = SharedRuntimePaths.whisperVenvPython()
        let bundledPythonURL = SharedRuntimePaths.whisperBundledPython()
        let scriptURL = SharedRuntimePaths.whisperTranscribeScript()
        let installed = FileManager.default.isExecutableFile(atPath: executableURL.path)
            && (FileManager.default.isExecutableFile(atPath: bundledPythonURL.path) || FileManager.default.isExecutableFile(atPath: pythonURL.path))
            && FileManager.default.fileExists(atPath: scriptURL.path)

        return FasterWhisperRuntimeStatus(
            isInstalled: installed,
            executableURL: executableURL,
            pythonURL: pythonURL,
            bundledPythonURL: bundledPythonURL,
            scriptURL: scriptURL
        )
    }

    func install(onProgress: @escaping (String) -> Void) async throws -> FasterWhisperRuntimeStatus {
        if let artifactURL = configuredArtifactURL() {
            onProgress("Installing Contora Whisper runtime artifact...")
            return try await installArtifact(from: artifactURL, onProgress: onProgress)
        }

        if ProcessInfo.processInfo.environment["CONTORA_MACOS_ENABLE_PYTHON_RUNTIME_BUILD"] != "1" {
            throw FasterWhisperRuntimeInstallError.artifactNotFound
        }

        return try installFromPythonEnvironment(onProgress: onProgress)
    }

    private func configuredArtifactURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let archive = env["CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE"], !archive.isEmpty {
            return URL(fileURLWithPath: archive)
        }
        if let url = env["CONTORA_MACOS_WHISPER_RUNTIME_URL"], !url.isEmpty {
            return URL(string: url)
        }
        if let bundled = bundledArtifactURL() {
            return bundled
        }
        return URL(string: "https://github.com/iamniketas/contora/releases/latest/download/ContoraMacWhisperRuntime-\(Self.runtimeArchitecture).tar.gz")
    }

    private func bundledArtifactURL() -> URL? {
        let fileNames = [
            "ContoraMacWhisperRuntime-\(Self.runtimeArchitecture).tar.gz",
            "ContoraMacWhisperRuntime.tar.gz"
        ]
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL
        ].compactMap { $0 }

        for root in roots {
            let searchRoots = [
                root,
                root.appendingPathComponent("Resources", isDirectory: true)
            ]
            for searchRoot in searchRoots {
                for fileName in fileNames {
                    let candidate = searchRoot.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    private static var runtimeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func installArtifact(from sourceURL: URL, onProgress: @escaping (String) -> Void) async throws -> FasterWhisperRuntimeStatus {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contora-whisper-runtime-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = temporaryDirectory.appendingPathComponent("runtime.tar.gz")
        let extractDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        if sourceURL.isFileURL {
            onProgress("Copying runtime artifact...")
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime artifact not found at \(sourceURL.path)")
            }
            try FileManager.default.copyItem(at: sourceURL, to: archiveURL)
            try validateChecksumIfPresent(archiveURL: archiveURL, sourceURL: sourceURL)
        } else {
            onProgress("Downloading runtime artifact...")
            let (downloadedURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime artifact download failed.")
            }
            try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)
        }

        onProgress("Extracting runtime artifact...")
        try FileManager.default.createDirectory(at: SharedRuntimePaths.whisperRoot(), withIntermediateDirectories: true)
        try run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archiveURL.path, "-C", extractDirectory.path])

        guard let extractedRoot = findExtractedRuntimeRoot(in: extractDirectory) else {
            throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime archive does not contain faster-whisper-xxl.")
        }

        guard validateExtractedRuntime(extractedRoot) else {
            throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime archive is incomplete.")
        }

        onProgress("Installing runtime files...")
        try installExtractedRuntime(from: extractedRoot)
        onProgress("Runtime installed")
        return status()
    }

    private func bundledChecksumURL(for artifactURL: URL) -> URL? {
        let checksumURL = artifactURL.appendingPathExtension("sha256")
        if FileManager.default.fileExists(atPath: checksumURL.path) {
            return checksumURL
        }
        return nil
    }

    private func validateChecksumIfPresent(archiveURL: URL, sourceURL: URL) throws {
        guard let checksumURL = bundledChecksumURL(for: sourceURL) else {
            return
        }

        let expectedLine = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expectedHash = expectedLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) else {
            throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime artifact checksum file is empty.")
        }

        let actualHash = try sha256(archiveURL)
        guard expectedHash.lowercased() == actualHash.lowercased() else {
            throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Runtime artifact checksum mismatch.")
        }
    }

    private func sha256(_ fileURL: URL) throws -> String {
        let output = try runAndCapture(URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "256", fileURL.path])
        guard let hash = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            throw FasterWhisperRuntimeInstallError.artifactInstallFailed("Could not read runtime artifact checksum.")
        }
        return String(hash)
    }

    private func findExtractedRuntimeRoot(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == "faster-whisper-xxl" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                continue
            }
            return url.deletingLastPathComponent()
        }
        return nil
    }

    private func installExtractedRuntime(from extractedRoot: URL) throws {
        let targetRoot = SharedRuntimePaths.whisperRoot()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        try makeWritable(targetRoot)
        let existingItems = (try? fileManager.contentsOfDirectory(at: targetRoot, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in existingItems where item.lastPathComponent != "_models" {
            try fileManager.removeItem(at: item)
        }

        let sourceItems = try fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for source in sourceItems where source.lastPathComponent != "_models" {
            let destination = targetRoot.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        try makeWritable(targetRoot)
    }

    func resetRuntime(preservingModels: Bool) throws {
        let targetRoot = SharedRuntimePaths.whisperRoot()
        guard FileManager.default.fileExists(atPath: targetRoot.path) else {
            return
        }
        try makeWritable(targetRoot)

        if preservingModels {
            let items = (try? FileManager.default.contentsOfDirectory(at: targetRoot, includingPropertiesForKeys: nil, options: [])) ?? []
            for item in items where item.lastPathComponent != "_models" {
                try FileManager.default.removeItem(at: item)
            }
        } else {
            try FileManager.default.removeItem(at: targetRoot)
        }
    }

    private func validateExtractedRuntime(_ root: URL) -> Bool {
        let executable = root.appendingPathComponent("faster-whisper-xxl")
        let script = root.appendingPathComponent("bin/contora_fw_transcribe.py")
        let bundledPython = root
            .appendingPathComponent("python/Python.framework/Versions/3.12/bin/python3.12")
        let venvPython = root.appendingPathComponent("venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: executable.path)
            && FileManager.default.fileExists(atPath: script.path)
            && (FileManager.default.isExecutableFile(atPath: bundledPython.path) || FileManager.default.isExecutableFile(atPath: venvPython.path))
    }

    private func makeWritable(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwX", root.path])
    }

    private func installFromPythonEnvironment(onProgress: @escaping (String) -> Void) throws -> FasterWhisperRuntimeStatus {
        let root = SharedRuntimePaths.whisperRoot()
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        onProgress("Resolving Python 3...")
        let systemPython = try resolvePython3()

        if !FileManager.default.fileExists(atPath: SharedRuntimePaths.whisperVenvPython().path) {
            onProgress("Creating Python runtime...")
            try run(systemPython, arguments: ["-m", "venv", root.appendingPathComponent("venv", isDirectory: true).path])
        }

        let venvPython = SharedRuntimePaths.whisperVenvPython()
        onProgress("Updating packaging tools...")
        try run(venvPython, arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])

        onProgress("Installing faster-whisper and diarization packages...")
        try run(venvPython, arguments: [
            "-m", "pip", "install", "--upgrade",
            "faster-whisper",
            "torch==2.4.1",
            "torchaudio==2.4.1",
            "pyannote.audio==3.4.0",
            "soundfile"
        ])

        onProgress("Writing Contora runtime wrapper...")
        try writeTranscribeScript()
        try writeExecutableWrapper()

        onProgress("Runtime installed")
        return status()
    }

    private func resolvePython3() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FasterWhisperRuntimeInstallError.pythonNotFound
        }

        guard process.terminationStatus == 0 else {
            throw FasterWhisperRuntimeInstallError.pythonNotFound
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw FasterWhisperRuntimeInstallError.pythonNotFound
        }

        return URL(fileURLWithPath: path)
    }

    private func run(_ executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let logURL = SharedRuntimePaths.whisperRoot().appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        logHandle.write("\n$ \(executableURL.path) \(arguments.joined(separator: " "))\n".data(using: .utf8)!)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? logHandle.close()
            throw FasterWhisperRuntimeInstallError.commandFailed(error.localizedDescription)
        }
        try? logHandle.close()

        guard process.terminationStatus == 0 else {
            let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let message = String(logText.suffix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FasterWhisperRuntimeInstallError.commandFailed(message.isEmpty ? "Command failed with exit \(process.terminationStatus)" : message)
        }
    }

    private func runAndCapture(_ executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FasterWhisperRuntimeInstallError.commandFailed(error.localizedDescription)
        }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = [stdout, stderr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw FasterWhisperRuntimeInstallError.commandFailed(message.isEmpty ? "Command failed with exit \(process.terminationStatus)" : message)
        }

        return stdout
    }

    private func writeExecutableWrapper() throws {
        let wrapper = """
        #!/bin/sh
        set -eu
        ROOT="$(cd "$(dirname "$0")" && pwd)"
        PYTHON_VERSION="${CONTORA_RUNTIME_PYTHON_VERSION:-3.12}"
        BUNDLED_PYTHON_HOME="$ROOT/python/Python.framework/Versions/$PYTHON_VERSION"
        BUNDLED_PYTHON="$BUNDLED_PYTHON_HOME/bin/python$PYTHON_VERSION"
        if [ -x "$BUNDLED_PYTHON" ]; then
          export PYTHONHOME="$BUNDLED_PYTHON_HOME"
          export PYTHONPATH="$ROOT/venv/lib/python$PYTHON_VERSION/site-packages${PYTHONPATH:+:$PYTHONPATH}"
          exec "$BUNDLED_PYTHON" "$ROOT/bin/contora_fw_transcribe.py" "$@"
        fi

        if [ -x "$ROOT/venv/bin/python" ]; then
          exec "$ROOT/venv/bin/python" "$ROOT/bin/contora_fw_transcribe.py" "$@"
        fi

        exec python3 "$ROOT/bin/contora_fw_transcribe.py" "$@"
        """

        let url = SharedRuntimePaths.whisperExecutable()
        try wrapper.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTranscribeScript() throws {
        let script = #"""
        #!/usr/bin/env python3
        import argparse
        import sys
        from pathlib import Path

        def timestamp(seconds: float) -> str:
            seconds = max(0.0, float(seconds or 0.0))
            whole = int(seconds)
            millis = int(round((seconds - whole) * 1000))
            if millis >= 1000:
                whole += 1
                millis = 0
            hours = whole // 3600
            minutes = (whole % 3600) // 60
            secs = whole % 60
            return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"

        def speaker_for_segment(segment, diarization):
            if diarization is None:
                return "SPEAKER_00"
            best_speaker = "SPEAKER_00"
            best_overlap = 0.0
            start = float(segment.start)
            end = float(segment.end)
            for turn, _, speaker in diarization.itertracks(yield_label=True):
                overlap = max(0.0, min(end, float(turn.end)) - max(start, float(turn.start)))
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_speaker = str(speaker)
            return best_speaker

        def load_diarization(audio_path: str, enabled: bool):
            if not enabled:
                return None
            try:
                from pyannote.audio import Pipeline
            except Exception as exc:
                print(f"pyannote.audio is unavailable: {exc}; using one speaker.", file=sys.stderr)
                return None

            runtime_root = Path(__file__).resolve().parents[1]
            candidates = [
                runtime_root / "pyannote" / "speaker-diarization-3.1",
                runtime_root / "models" / "pyannote" / "speaker-diarization-3.1",
            ]
            model_path = next((path for path in candidates if path.exists()), None)
            if model_path is None:
                print("Diarization requested but no bundled pyannote model was found; using one speaker.", file=sys.stderr)
                return None

            try:
                config_path = model_path / "config.yaml"
                local_config_path = runtime_root / "pyannote" / "speaker-diarization-3.1.local.yaml"
                config_text = config_path.read_text(encoding="utf-8")
                config_text = config_text.replace(
                    "segmentation: pyannote/segmentation-3.0",
                    "\n".join([
                        "segmentation:",
                        f"      checkpoint: {runtime_root / 'pyannote' / 'segmentation-3.0' / 'pytorch_model.bin'}",
                    ]),
                )
                config_text = config_text.replace(
                    "embedding: pyannote/wespeaker-voxceleb-resnet34-LM",
                    "\n".join([
                        "embedding:",
                        f"      checkpoint: {runtime_root / 'pyannote' / 'wespeaker-voxceleb-resnet34-LM' / 'pytorch_model.bin'}",
                    ]),
                )
                local_config_path.write_text(config_text, encoding="utf-8")
                pipeline = Pipeline.from_pretrained(str(local_config_path))
                return pipeline(audio_path)
            except Exception as exc:
                print(f"Bundled diarization unavailable: {exc}; using one speaker.", file=sys.stderr)
                return None

        def main() -> int:
            parser = argparse.ArgumentParser()
            parser.add_argument("-pp", "--print_progress", action="store_true")
            parser.add_argument("-o", "--output_dir", default=".")
            parser.add_argument("--output_dir_alt", dest="output_dir_alt")
            parser.add_argument("--standard", action="store_true")
            parser.add_argument("-f", "--output_format", default="txt")
            parser.add_argument("--output_format_alt", dest="output_format_alt")
            parser.add_argument("-m", "--model", default="large-v2")
            parser.add_argument("--model_dir")
            parser.add_argument("--language", default=None)
            parser.add_argument("--task", default="transcribe")
            parser.add_argument("--diarize", nargs="?", const="pyannote_v3.1", default=None)
            parser.add_argument("audio")
            args = parser.parse_args()

            try:
                from faster_whisper import WhisperModel
            except Exception as exc:
                print(f"faster-whisper is not installed: {exc}", file=sys.stderr)
                return 2

            model_size_or_path = args.model
            if args.model_dir:
                candidate = Path(args.model_dir) / f"faster-whisper-{args.model}"
                if candidate.exists():
                    model_size_or_path = str(candidate)

            output_dir = Path(args.output_dir_alt or args.output_dir)
            output_dir.mkdir(parents=True, exist_ok=True)
            audio_path = Path(args.audio)
            output_path = output_dir / f"{audio_path.stem}.txt"

            model = WhisperModel(model_size_or_path, device="auto", compute_type="auto")
            segments_iter, _ = model.transcribe(
                str(audio_path),
                language=args.language or None,
                task=args.task,
                vad_filter=True,
            )
            segments = list(segments_iter)
            diarization = load_diarization(str(audio_path), args.diarize is not None)

            with output_path.open("w", encoding="utf-8") as handle:
                for segment in segments:
                    speaker = speaker_for_segment(segment, diarization)
                    text = (segment.text or "").strip()
                    if not text:
                        continue
                    handle.write(f"[{timestamp(segment.start)} --> {timestamp(segment.end)}] [{speaker}]: {text}\n")

            if args.print_progress:
                print("100% | completed")
            return 0

        if __name__ == "__main__":
            raise SystemExit(main())
        """#

        let url = SharedRuntimePaths.whisperTranscribeScript()
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
