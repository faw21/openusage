import XCTest
@testable import OpenUsage

@MainActor
final class DevinProviderTests: XCTestCase {
    func testRefreshUsesCredentialsFileBeforeAppState() async throws {
        let httpClient = DevinQueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try makeDevinUserStatusBody())
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: DevinFakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(httpClient.requests.first?.url.absoluteString, "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        let body = try devinRequestBody(httpClient.requests.first)
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["apiKey"] as? String, "devin-session-token$cli")
        XCTAssertEqual(metadata?["ideName"] as? String, "devin")
        XCTAssertEqual(metadata?["extensionVersion"] as? String, DevinUsageClient.cloudCompatVersion)
    }

    func testRefreshFallsBackToAppStateAfterExpiredCredentials() async throws {
        let httpClient = DevinQueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: try makeDevinUserStatusBody(planName: "Teams"))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: DevinFakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Teams")
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [
            "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        ])
    }

    func testRefreshReturnsLoginHintWithoutAuth() async {
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: DevinFakeSQLite()),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.notLoggedIn.localizedDescription)
        // The final fallback must carry a real telemetry category (regression: it once used the
        // message-only factory, leaving errorCategory nil so failures bucketed as `other`).
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testCredentialProbeIsFalseOnlyForProvenAbsence() async {
        let absent = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: DevinFakeSQLite()),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )
        let unreadableFile = DevinProvider(
            authStore: DevinAuthStore(files: DevinUnreadableFiles(), sqlite: DevinFakeSQLite()),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )
        let unreadableDatabase = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles(),
                sqlite: DevinFakeSQLite(queryError: DevinCredentialBoundaryTestError.unreadable)
            ),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )

        let absentDetected = await absent.hasLocalCredentials()
        let unreadableFileDetected = await unreadableFile.hasLocalCredentials()
        let unreadableDatabaseDetected = await unreadableDatabase.hasLocalCredentials()
        XCTAssertFalse(absentDetected)
        XCTAssertTrue(unreadableFileDetected)
        XCTAssertTrue(unreadableDatabaseDetected)
    }

    func testRefreshSurfacesUnreadableCredentialStoreWhenNoFallbackLoads() async {
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: DevinUnreadableFiles(), sqlite: DevinFakeSQLite()),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.credentialStoreUnreadable.localizedDescription)
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testRefreshSurfacesMalformedCredentialDataWhenNoFallbackLoads() async {
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = \"unterminated"]),
                sqlite: DevinFakeSQLite()
            ),
            usageClient: DevinUsageClient(http: DevinQueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.invalidCredentialData.localizedDescription)
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshFallsBackToAppStateAfterMalformedCLIFile() async throws {
        let httpClient = DevinQueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try makeDevinUserStatusBody(planName: "Teams"))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "http://unsafe.example"
                    """
                ]),
                sqlite: DevinFakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Teams")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        ])
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}
