import Darwin
import Foundation

@main
struct BundledPythonRepairSmokeTest {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeError.runtimeRootMissing
        }

        let sharedRoot = CommandLine.arguments[1]
        setenv(SharedRuntimePaths.envRuntimeRoot, sharedRoot, 1)
        try FasterWhisperRuntimeInstaller().repairInstalledRuntimeIfNeeded()

        let framework = SharedRuntimePaths.whisperRoot()
            .appendingPathComponent("python/Python.framework/Versions/3.12", isDirectory: true)
        let targets = [
            framework.appendingPathComponent("lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so"),
            framework.appendingPathComponent("lib/python3.12/lib-dynload/_hashlib.cpython-312-darwin.so"),
            framework.appendingPathComponent("lib/libssl.3.dylib"),
        ]
        let forbiddenPrefix = "/Library/Frameworks/Python.framework/Versions/3.12/lib/"

        for target in targets {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
            process.arguments = ["-L", target.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            guard process.terminationStatus == 0, !text.contains(forbiddenPrefix) else {
                throw SmokeError.absoluteDependencyRemains(target.path)
            }
        }

        print("Bundled Python relocation smoke test passed")
    }
}

enum SmokeError: Error {
    case runtimeRootMissing
    case absoluteDependencyRemains(String)
}
