import XCTest
@testable import OpenUsage

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files)

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }

    func testMissingAuthFileIsProvenAbsent() throws {
        let store = GrokAuthStore(files: FakeFiles())

        XCTAssertTrue(try store.loadAuthCandidates().isEmpty)
    }

    func testUnreadableAuthFileThrowsCredentialStoreUnreadable() {
        let store = GrokAuthStore(files: GrokUnreadableFiles())

        XCTAssertThrowsError(try store.loadAuthCandidates()) { error in
            XCTAssertEqual(error as? GrokAuthError, .credentialStoreUnreadable)
        }
    }

    func testMalformedAuthFileThrowsInvalidAuth() {
        let store = GrokAuthStore(files: FakeFiles([GrokAuthStore.authPath: "{ not-json"]))

        XCTAssertThrowsError(try store.loadAuthCandidates()) { error in
            XCTAssertEqual(error as? GrokAuthError, .invalidAuth)
        }
    }

    @MainActor
    func testCredentialProbeAndRefreshDistinguishAbsentUnreadableAndMalformed() async {
        let absent = makeBoundaryProvider(files: FakeFiles())
        let absentDetected = await absent.hasLocalCredentials()
        XCTAssertFalse(absentDetected)
        let absentSnapshot = await absent.refresh()
        XCTAssertEqual(absentSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(absentSnapshot), GrokAuthError.notLoggedIn.localizedDescription)

        let unreadable = makeBoundaryProvider(files: GrokUnreadableFiles())
        let unreadableDetected = await unreadable.hasLocalCredentials()
        XCTAssertTrue(unreadableDetected, "an uncertain one-shot probe must be conservative")
        let unreadableSnapshot = await unreadable.refresh()
        XCTAssertEqual(unreadableSnapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(unreadableSnapshot), GrokAuthError.credentialStoreUnreadable.localizedDescription)

        let malformed = makeBoundaryProvider(files: FakeFiles([GrokAuthStore.authPath: "{ not-json"]))
        let malformedDetected = await malformed.hasLocalCredentials()
        XCTAssertTrue(malformedDetected, "a present malformed store must be enabled to show its error")
        let malformedSnapshot = await malformed.refresh()
        XCTAssertEqual(malformedSnapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(malformedSnapshot), GrokAuthError.invalidAuth.localizedDescription)
    }

    func testSaveRefusesToOverwriteACorruptAuthFile() throws {
        // A present-but-corrupt auth.json must NOT be silently rebuilt from in-memory state (which
        // would drop other accounts' entries). save() must throw and leave the file untouched.
        let validJSON = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        let files = FakeFiles([GrokAuthStore.authPath: validJSON])
        let store = GrokAuthStore(files: files, now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.entry.key = "rotated-token"

        // Corrupt the file on disk, then attempt to persist the rotation.
        let corrupt = "{ not valid json"
        files.files[GrokAuthStore.authPath] = corrupt

        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(files.files[GrokAuthStore.authPath], corrupt, "corrupt file must be left untouched, not clobbered")
    }
}

@MainActor
private func makeBoundaryProvider(files: TextFileAccessing) -> GrokProvider {
    GrokProvider(
        authStore: GrokAuthStore(files: files),
        usageClient: GrokUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))),
        logUsageScanner: GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/none") }
        ),
        pricing: { TestPricing.bundled }
    )
}

private func errorText(_ snapshot: ProviderSnapshot) -> String? {
    guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
    return text
}

private struct GrokUnreadableFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { throw CredentialBoundaryTestError.unreadable }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private enum CredentialBoundaryTestError: Error {
    case unreadable
}

private func makeJWT(exp: Int) -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
