import XCTest
@testable import OpenUsageCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndAgentOptions() throws {
        let parsed = try CLIArguments.parse(["Claude", "--json", "--no-launch"])
        XCTAssertEqual(parsed.providerID, "claude")
        XCTAssertEqual(parsed.output, .json)
        XCTAssertFalse(parsed.launchApp)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--wat"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }

    func testExecutableLocatorPrefersRealExecutableWhenArgumentZeroIsBareCommand() {
        let executable = URL(fileURLWithPath: "/Applications/OpenUsage.app/Contents/Helpers/openusage")

        let resolved = ExecutableLocator.current(
            argument0: "openusage",
            bundleExecutableURL: executable
        )

        XCTAssertEqual(resolved, executable)
    }
}
