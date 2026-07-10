import XCTest
@testable import OpenUsage

@MainActor
final class CopilotCredentialBoundaryTests: XCTestCase {
    func testMissingSourcesRemainAbsent() async {
        let provider = makeProvider(files: FakeFiles(), keychain: FakeKeychain())

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.notLoggedIn.localizedDescription)
    }

    func testUnreadableEditorFileIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: CopilotBoundaryFiles([CopilotAuthStore.editorAppsPath: .unreadable]),
            keychain: FakeKeychain()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedEditorFileIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: FakeFiles([CopilotAuthStore.editorAppsPath: "{ not-json"]),
            keychain: FakeKeychain()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.invalidCredentialData.localizedDescription)
    }

    func testMalformedAppsFileDoesNotHideValidOlderEditorFile() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: "{ not-json",
                CopilotAuthStore.editorHostsPath: #"{"github.com":{"oauth_token":"editor-token"}}"#
            ]),
            keychain: FakeKeychain()
        )

        let load = store.loadTokenResult()

        XCTAssertEqual(load.token?.value, "editor-token")
        XCTAssertNil(load.firstError)
    }

    func testMalformedEditorFileDoesNotHideValidGhConfig() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: "{ not-json",
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    user: octocat
                    oauth_token: gh-config-token
                """
            ]),
            keychain: FakeKeychain()
        )

        let load = store.loadTokenResult()

        XCTAssertEqual(load.token?.value, "gh-config-token")
        XCTAssertNil(load.firstError)
    }

    func testUnreadableGhConfigDoesNotHideValidServiceKeychainToken() {
        let wrapped = "go-keyring-base64:" + Data("keychain-token".utf8).base64EncodedString()
        let store = CopilotAuthStore(
            files: CopilotBoundaryFiles([CopilotAuthStore.ghHostsPath: .unreadable]),
            keychain: FakeKeychain(wrapped)
        )

        let load = store.loadTokenResult()

        XCTAssertEqual(load.token?.value, "keychain-token")
        XCTAssertNil(load.firstError)
    }

    func testMalformedGhConfigIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: FakeFiles([CopilotAuthStore.ghHostsPath: "not a host map"]),
            keychain: FakeKeychain()
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.invalidCredentialData.localizedDescription)
    }

    func testMalformedAccountKeychainEntryDoesNotHideValidServiceEntry() {
        let wrapped = "go-keyring-base64:" + Data("service-token".utf8).base64EncodedString()
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    user: octocat
                """
            ]),
            keychain: CopilotBoundaryKeychain(
                accountValue: "go-keyring-base64:not-base64",
                serviceValue: wrapped
            )
        )

        let load = store.loadTokenResult()

        XCTAssertEqual(load.token?.value, "service-token")
        XCTAssertNil(load.firstError)
    }

    func testEnterpriseOnlyFilesAreCompatibleAbsence() async {
        let files = FakeFiles([
            CopilotAuthStore.editorAppsPath:
                #"{"ghe.corp.example:Iv1.enterprise":{"oauth_token":"enterprise-token"}}"#,
            CopilotAuthStore.ghHostsPath: """
            ghe.corp.example:
                user: enterprise-user
                oauth_token: enterprise-token
            """
        ])
        let provider = makeProvider(files: files, keychain: FakeKeychain())

        let load = provider.authStore.loadTokenResult()
        XCTAssertNil(load.token)
        XCTAssertNil(load.firstError, "Enterprise-only files are valid but cannot serve api.github.com")
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testLookalikeGithubHostDoesNotLeakItsTokenToDotCom() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:enterprise:
                    user: enterprise-user
                    oauth_token: enterprise-token
                """
            ]),
            keychain: FakeKeychain()
        )

        let load = store.loadTokenResult()

        XCTAssertNil(load.token)
        XCTAssertNil(load.firstError, "a valid non-dot-com host is compatible absence")
    }

    func testGithubConfigWithoutInlineTokenCanUseAnAbsentKeychain() async {
        let files = FakeFiles([
            CopilotAuthStore.ghHostsPath: """
            github.com:
                user: octocat
                git_protocol: https
            """
        ])
        let provider = makeProvider(files: files, keychain: FakeKeychain())

        let load = provider.authStore.loadTokenResult()
        XCTAssertNil(load.token)
        XCTAssertNil(load.firstError, "gh can keep the token in Keychain instead of hosts.yml")
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
    }

    func testMalformedKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: FakeFiles(),
            keychain: FakeKeychain("go-keyring-base64:not-base64")
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.invalidCredentialData.localizedDescription)
    }

    func testUnreadableKeychainIsConservativelyDetectedAndSurfaced() async {
        let provider = makeProvider(
            files: FakeFiles(),
            keychain: CopilotBoundaryKeychain(serviceReadFails: true)
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot), CopilotAuthError.credentialStoreUnreadable.localizedDescription)
    }

    private func makeProvider(
        files: TextFileAccessing,
        keychain: KeychainAccessing
    ) -> CopilotProvider {
        CopilotProvider(
            authStore: CopilotAuthStore(files: files, keychain: keychain),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            )),
            defaults: UserDefaults(suiteName: "CopilotCredentialBoundaryTests.\(UUID().uuidString)")!
        )
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
        return text
    }
}

private final class CopilotBoundaryFiles: TextFileAccessing, @unchecked Sendable {
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
        case .unreadable: throw CopilotBoundaryTestError.unreadable
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

private struct CopilotBoundaryKeychain: KeychainAccessing {
    var accountValue: String?
    var serviceValue: String?
    var accountReadFails: Bool
    var serviceReadFails: Bool

    init(
        accountValue: String? = nil,
        serviceValue: String? = nil,
        accountReadFails: Bool = false,
        serviceReadFails: Bool = false
    ) {
        self.accountValue = accountValue
        self.serviceValue = serviceValue
        self.accountReadFails = accountReadFails
        self.serviceReadFails = serviceReadFails
    }

    func readGenericPassword(service: String) throws -> String? {
        if serviceReadFails { throw CopilotBoundaryTestError.unreadable }
        return serviceValue
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        if accountReadFails { throw CopilotBoundaryTestError.unreadable }
        return accountValue
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

private enum CopilotBoundaryTestError: Error {
    case unreadable
}
