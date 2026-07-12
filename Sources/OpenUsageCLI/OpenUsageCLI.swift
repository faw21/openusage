import Darwin
import Foundation

@main
struct OpenUsageCLI {
    static func main() async {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.showHelp {
                print(help)
                return
            }
            if arguments.showVersion {
                print(version())
                return
            }

            let result = try await fetch(arguments)
            let jsonOutput = arguments.output == .json
                || (arguments.output == .automatic && isatty(STDOUT_FILENO) == 0)
            if jsonOutput {
                FileHandle.standardOutput.write(result.0)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(TerminalRenderer.render(result.1))
            }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch CLIError.appUnavailable {
            fail("OpenUsage is not running. Open the app and try again, or omit --no-launch.", code: 3)
        } catch CLIError.request(let message) {
            fail("Could not read usage: \(message)", code: 4)
        } catch {
            fail("Could not read usage: \(error.localizedDescription)", code: 4)
        }
    }

    private static func fetch(_ arguments: CLIArguments) async throws -> (Data, [UsageSnapshot]) {
        let client = UsageAPIClient()
        do {
            return try await client.fetch(providerID: arguments.providerID)
        } catch CLIError.appUnavailable where arguments.launchApp {
            try launchContainingApp()
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                do {
                    let result = try await client.fetch(providerID: arguments.providerID)
                    return result
                } catch CLIError.appUnavailable {
                    continue
                } catch {
                    // The app now owns the port and returned a meaningful HTTP/decode/transport error.
                    // Surface it immediately instead of retrying until it is mislabeled "not running".
                    throw error
                }
            }
            throw CLIError.appUnavailable
        }
    }

    private static func launchContainingApp() throws {
        let executable = ExecutableLocator.current()
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { throw CLIError.appUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gja", appURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.appUnavailable }
    }

    private static func version() -> String {
        let executable = ExecutableLocator.current()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String else {
            return "openusage (development build)"
        }
        return "openusage \(version)"
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("openusage: \(message)\n".utf8))
        exit(code)
    }

    private static let help = """
    Usage: openusage [provider] [options]

    Read the latest usage collected by the OpenUsage menu-bar app.

    Options:
      --json       Print the stable JSON wire format
      --table      Print a compact human-readable table
      --no-launch  Do not launch OpenUsage when it is not running
      -v, --version
      -h, --help

    Output defaults to a table in a terminal and JSON when piped, making
    `openusage` directly consumable by agents and scripts.
    """
}

enum ExecutableLocator {
    static func current(
        argument0: String = CommandLine.arguments[0],
        bundleExecutableURL: URL? = Bundle.main.executableURL
    ) -> URL {
        let executable = bundleExecutableURL ?? URL(fileURLWithPath: argument0)
        return executable.resolvingSymlinksInPath().standardizedFileURL
    }
}
