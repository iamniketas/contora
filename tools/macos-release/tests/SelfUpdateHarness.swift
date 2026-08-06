import Darwin
import Foundation

@main
struct SelfUpdateHarness {
    static func main() {
        if SelfUpdateInstaller.handleCommandLineIfNeeded() {
            return
        }

        guard CommandLine.arguments.count == 3 else {
            fputs("usage: updater-harness <update.zip> <version>\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            try SelfUpdateInstaller.stageAndLaunchHelper(
                archiveURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                expectedVersion: CommandLine.arguments[2]
            )
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
