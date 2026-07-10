import XCTest
@testable import OpenUsage

final class DevinAuthStoreTests: XCTestCase {
    func testParsesCredentialsTomlAndCleansServerURL() throws {
        let store = DevinAuthStore(
            files: FakeFiles([
                DevinAuthStore.credentialsPath: """
                windsurf_api_key = "devin-session-token$cli"
                api_server_url = "https://server.codeium.test/"
                """
            ]),
            sqlite: DevinFakeSQLite()
        )

        let auth = try store.loadCredentialsFile()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$cli")
        XCTAssertEqual(auth?.apiServerUrl, "https://server.codeium.test")
    }

    func testRejectsPlaintextServerURLInsteadOfFallingBackToProduction() {
        let store = DevinAuthStore(
            files: FakeFiles([
                DevinAuthStore.credentialsPath: """
                windsurf_api_key = "devin-session-token$cli"
                api_server_url = "http://server.codeium.test"
                """
            ]),
            sqlite: DevinFakeSQLite()
        )

        XCTAssertThrowsError(try store.loadCredentialsFile()) { error in
            XCTAssertEqual(error as? DevinAuthError, .invalidCredentialData)
        }
    }

    func testReadsAppAuthFromSQLiteState() throws {
        let sqlite = DevinFakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
        let store = DevinAuthStore(files: FakeFiles(), sqlite: sqlite)

        let auth = try store.loadAppAuth()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$app")
        XCTAssertEqual(sqlite.lastPath, DevinAuthStore.stateDBPath)
        XCTAssertEqual(sqlite.lastSQL?.contains("windsurfAuthStatus"), true)
    }

    func testMissingCredentialSourcesAreProvenAbsent() throws {
        let store = DevinAuthStore(files: FakeFiles(), sqlite: DevinFakeSQLite())

        XCTAssertNil(try store.loadCredentialsFile())
        XCTAssertNil(try store.loadAppAuth())
    }

    func testUnreadableCredentialFileThrowsCredentialStoreUnreadable() {
        let store = DevinAuthStore(files: DevinUnreadableFiles(), sqlite: DevinFakeSQLite())

        XCTAssertThrowsError(try store.loadCredentialsFile()) { error in
            XCTAssertEqual(error as? DevinAuthError, .credentialStoreUnreadable)
        }
    }

    func testMalformedCredentialFileThrowsInvalidCredentialData() {
        let store = DevinAuthStore(
            files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = \"unterminated"]),
            sqlite: DevinFakeSQLite()
        )

        XCTAssertThrowsError(try store.loadCredentialsFile()) { error in
            XCTAssertEqual(error as? DevinAuthError, .invalidCredentialData)
        }
    }

    func testUnreadableAppDatabaseThrowsCredentialStoreUnreadable() {
        let store = DevinAuthStore(
            files: FakeFiles(),
            sqlite: DevinFakeSQLite(queryError: DevinCredentialBoundaryTestError.unreadable)
        )

        XCTAssertThrowsError(try store.loadAppAuth()) { error in
            XCTAssertEqual(error as? DevinAuthError, .credentialStoreUnreadable)
        }
    }

    func testMalformedAppDatabaseValueThrowsInvalidCredentialData() {
        let store = DevinAuthStore(files: FakeFiles(), sqlite: DevinFakeSQLite(value: "{ not-json"))

        XCTAssertThrowsError(try store.loadAppAuth()) { error in
            XCTAssertEqual(error as? DevinAuthError, .invalidCredentialData)
        }
    }

    func testSignedOutAppDatabaseValueIsAbsent() throws {
        let store = DevinAuthStore(files: FakeFiles(), sqlite: DevinFakeSQLite(value: #"{"signedIn":false}"#))

        XCTAssertNil(try store.loadAppAuth())
    }
}
