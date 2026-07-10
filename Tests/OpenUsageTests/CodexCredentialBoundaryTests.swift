import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialBoundaryTests: XCTestCase {
    func testMissingSourcesRemainAbsent() async {
        let provider = makeProvider(files: FakeFiles(), keychain: FakeKeychain())

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.notLoggedIn.localizedDescription)
    }

    func testUnreadableFileIsConservativelyDetectedAndSurfaced() async {
        let files = CodexBoundaryFiles([
            "~/.config/codex/auth.json": .unreadable
        ])
        let provider = makeProvider(files: files, keychain: FakeKeychain())

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedFileIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: FakeFiles(["~/.config/codex/auth.json": "{ not-json"]),
            keychain: FakeKeychain()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.invalidAuthPayload.localizedDescription)
    }

    func testMalformedKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(files: FakeFiles(), keychain: FakeKeychain("{ not-json"))

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.invalidAuthPayload.localizedDescription)
    }

    func testUnreadableKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(files: FakeFiles(), keychain: CodexBoundaryKeychain(readFails: true))

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.credentialStoreUnreadable.localizedDescription)
    }

    func testLaterOAuthFileWinsAfterMalformedSibling() async {
        let http = successfulHTTP()
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json": "{ not-json",
                "~/.codex/auth.json": #"{"tokens":{"access_token":"oauth-file-token"}}"#
            ]),
            keychain: FakeKeychain(),
            http: http
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(usageAuthorizations(in: http), ["Bearer oauth-file-token"])
    }

    func testKeychainOAuthWinsAfterUnreadableFile() async {
        let http = successfulHTTP()
        let provider = makeProvider(
            files: CodexBoundaryFiles(["~/.config/codex/auth.json": .unreadable]),
            keychain: FakeKeychain(#"{"tokens":{"access_token":"keychain-token"}}"#),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(usageAuthorizations(in: http), ["Bearer keychain-token"])
    }

    func testAPIKeyOnlyAuthIsSupportedButDoesNotSeedSubscriptionUsage() async {
        let provider = makeProvider(
            files: FakeFiles(["~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#]),
            keychain: FakeKeychain()
        )

        let load = provider.authStore.loadAuthResult()
        XCTAssertNil(load.firstError, "API-key-only auth is valid syntax, not malformed")
        XCTAssertEqual(load.candidates.first?.auth.apiKey, "sk-api-only")
        XCTAssertFalse(load.candidates.first?.hasUsableAccessToken == true)
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.usageAPIKey.localizedDescription)
    }

    func testValidAPIKeyGuidanceTakesPrecedenceOverBrokenSibling() async {
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#,
                "~/.codex/auth.json": "{ not-json"
            ]),
            keychain: FakeKeychain()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected, "the broken sibling makes one-shot detection conservative")
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertEqual(errorText(snapshot), CodexAuthError.usageAPIKey.localizedDescription)
    }

    private func makeProvider(
        files: TextFileAccessing,
        keychain: KeychainAccessing,
        http: FakeHTTPClient = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    ) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(),
                files: files,
                keychain: keychain
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )
    }

    private func successfulHTTP() -> FakeHTTPClient {
        FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
    }

    private func usageAuthorizations(in http: FakeHTTPClient) -> [String?] {
        http.requests
            .filter { $0.url == CodexUsageClient.usageURL }
            .map { $0.headers["Authorization"] }
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
        return text
    }
}

private final class CodexBoundaryFiles: TextFileAccessing, @unchecked Sendable {
    enum Entry {
        case text(String)
        case unreadable
    }

    private var entries: [String: Entry]

    init(_ entries: [String: Entry]) {
        self.entries = entries
    }

    func exists(_ path: String) -> Bool {
        entries[path] != nil
    }

    func readText(_ path: String) throws -> String {
        switch entries[path] {
        case .text(let text): return text
        case .unreadable: throw CodexBoundaryTestError.unreadable
        case nil: return ""
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        entries[path] = .text(text)
    }

    func remove(_ path: String) throws {
        entries.removeValue(forKey: path)
    }
}

private enum CodexBoundaryTestError: Error {
    case unreadable
}

private struct CodexBoundaryKeychain: KeychainAccessing {
    var value: String?
    var readFails: Bool

    init(value: String? = nil, readFails: Bool = false) {
        self.value = value
        self.readFails = readFails
    }

    func readGenericPassword(service: String) throws -> String? {
        if readFails { throw CodexBoundaryTestError.unreadable }
        return value
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        if readFails { throw CodexBoundaryTestError.unreadable }
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {}
}
