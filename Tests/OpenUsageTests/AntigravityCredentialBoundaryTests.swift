import XCTest
@testable import OpenUsage

@MainActor
final class AntigravityCredentialBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingSourcesRemainAbsent() async {
        let provider = makeProvider(keychain: FakeKeychain(), files: FakeFiles())

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), AntigravityError.notSignedIn.localizedDescription)
    }

    func testUnreadableKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            keychain: AntigravityBoundaryKeychain(readFails: true),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), AntigravityError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedWrappedKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            keychain: FakeKeychain("go-keyring-base64:not-base64"),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), AntigravityError.invalidCredentialData.localizedDescription)
    }

    func testJSONKeychainWithoutTokensIsMalformedNotARawBearerToken() async {
        let provider = makeProvider(
            keychain: FakeKeychain(#"{"account":"present-but-tokenless"}"#),
            files: FakeFiles()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), AntigravityError.invalidCredentialData.localizedDescription)
    }

    func testValidCacheWinsAfterKeychainReadFailure() async {
        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = makeProvider(
            keychain: AntigravityBoundaryKeychain(readFails: true),
            files: FakeFiles([AntigravityAuthStore.cachePath: cachedToken(expiresIn: 3_600)]),
            http: routing
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(routing.requests.contains { $0.url.path.contains("retrieveUserQuotaSummary") })
    }

    func testCorruptAppOwnedCacheIsIgnoredRatherThanSurfacedAsPrimaryCredentialFailure() async {
        let provider = makeProvider(
            keychain: FakeKeychain(),
            files: FakeFiles([AntigravityAuthStore.cachePath: "{ not-json"])
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), AntigravityError.notSignedIn.localizedDescription)
    }

    func testUnreadableAppOwnedCacheIsIgnoredRatherThanSurfacedAsPrimaryCredentialFailure() async {
        let provider = makeProvider(
            keychain: FakeKeychain(),
            files: AntigravityBoundaryFiles([AntigravityAuthStore.cachePath: .unreadable])
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testExpiredAppOwnedCacheIsANormalMiss() async {
        let provider = makeProvider(
            keychain: FakeKeychain(),
            files: FakeFiles([AntigravityAuthStore.cachePath: cachedToken(expiresIn: 30)])
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    private func makeProvider(
        keychain: KeychainAccessing,
        files: TextFileAccessing,
        http: HTTPClient = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    ) -> AntigravityProvider {
        let fixedNow = now
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: keychain, files: files, now: { fixedNow }),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: AntigravityNoProcessRunner()),
            now: { fixedNow }
        )
    }

    private func cachedToken(expiresIn: TimeInterval) -> String {
        let expiresAtMs = (now.timeIntervalSince1970 + expiresIn) * 1_000
        return #"{"accessToken":"cached-access-token","expiresAtMs":\#(expiresAtMs)}"#
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
        return text
    }
}

private struct AntigravityBoundaryKeychain: KeychainAccessing {
    var value: String?
    var readFails: Bool

    init(value: String? = nil, readFails: Bool = false) {
        self.value = value
        self.readFails = readFails
    }

    func readGenericPassword(service: String) throws -> String? {
        if readFails { throw AntigravityBoundaryTestError.unreadable }
        return value
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        if readFails { throw AntigravityBoundaryTestError.unreadable }
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

private final class AntigravityBoundaryFiles: TextFileAccessing, @unchecked Sendable {
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
        case .unreadable: throw AntigravityBoundaryTestError.unreadable
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

private struct AntigravityNoProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private enum AntigravityBoundaryTestError: Error {
    case unreadable
}
