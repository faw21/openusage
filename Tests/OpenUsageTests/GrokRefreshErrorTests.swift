import XCTest
@testable import OpenUsage

@MainActor
final class GrokRefreshErrorTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
    private let expiredAuth = #"{"https://auth.x.ai::client":{"key":"expired-token","refresh_token":"refresh","expires_at":"2026-01-01T00:00:00.000Z"}}"#

    func testExpiredTokenRefreshTransportFailureReportsNetworkError() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                throw URLError(.notConnectedToInternet)
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: expiredAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(errorText(snapshot), "Grok token refresh failed. Check your connection.")
        XCTAssertFalse(http.requests.contains { $0.url == GrokUsageClient.creditsConfigURL })
    }

    func testAuthRetryRefreshServerFailureReportsHTTPError() async {
        var creditsCalls = 0
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                creditsCalls += 1
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(errorText(snapshot), "Grok token refresh failed (HTTP 503). Try again later.")
        XCTAssertEqual(creditsCalls, 1, "a failed refresh must not retry billing with the rejected token")
    }

    func testMalformedSuccessfulRefreshReportsDecodingError() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"unexpected":true}"#.utf8))
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: expiredAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertEqual(errorText(snapshot), "Grok token refresh response changed.")
    }

    func testInvalidExplicitExpiryReportsDecodingWithoutRewritingAuthFile() async {
        let jwtAccessToken = "a.eyJleHAiOjE3NzAwMDM2MDB9.c"
        XCTAssertNotNil(GrokAuthStore().tokenExpiresAt(jwtAccessToken))
        let cases = [
            (expiresIn: "0", accessToken: jwtAccessToken),
            (expiresIn: "-60", accessToken: "new-token"),
            (expiresIn: "1e400", accessToken: "new-token")
        ]
        for testCase in cases {
            let originalAuth = expiredAuth
            let files = FakeFiles([GrokAuthStore.authPath: originalAuth])
            let http = RefreshHTTPClient { request in
                if request.url == GrokUsageClient.refreshURL {
                    let body = #"{"access_token":"\#(testCase.accessToken)","refresh_token":"new-refresh","expires_in":\#(testCase.expiresIn)}"#
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
                }
                return Self.defaultRoute(request)
            }

            let snapshot = await makeProvider(http: http, files: files).refresh()

            XCTAssertEqual(snapshot.errorCategory, .decoding, "expires_in=\(testCase.expiresIn)")
            XCTAssertEqual(errorText(snapshot), "Grok token refresh response changed.")
            XCTAssertEqual(files.files[GrokAuthStore.authPath], originalAuth, "expires_in=\(testCase.expiresIn)")
        }
    }

    func testWhitespaceOnlyAccessTokenReportsDecodingWithoutRewritingAuthFile() async {
        let originalAuth = expiredAuth
        let files = FakeFiles([GrokAuthStore.authPath: originalAuth])
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                let body = #"{"access_token":"   ","refresh_token":"new-refresh","expires_in":3600}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, files: files).refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertEqual(files.files[GrokAuthStore.authPath], originalAuth)
    }

    func testRateLimitedRefreshKeepsRateLimitClassification() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 429, headers: [:], body: Data())
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: expiredAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
        XCTAssertEqual(errorText(snapshot), "Grok token refresh failed (HTTP 429). Try again later.")
    }

    func testRejectedRefreshTokenStillReportsExpiredAuth() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: expiredAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(errorText(snapshot), GrokAuthError.expired.localizedDescription)
    }

    func testUnrecognizedRefreshRejectionDoesNotClaimTheLoginExpired() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_request"}"#.utf8))
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: expiredAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .http4xx)
        XCTAssertEqual(errorText(snapshot), "Grok token refresh failed (HTTP 400). Try again later.")
    }

    func testFailedProactiveRefreshStillTriesCurrentUnexpiredToken() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return Self.defaultRoute(request)
        }
        let currentAuth = #"{"https://auth.x.ai::client":{"key":"current-token","refresh_token":"refresh","expires_at":"2026-02-02T00:02:00.000Z"}}"#

        let snapshot = await makeProvider(http: http, authJSON: currentAuth).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.lines.first { $0.label == "Weekly limit" })
        XCTAssertTrue(http.requests.contains { request in
            request.url == GrokUsageClient.creditsConfigURL
                && request.headers["Authorization"] == "Bearer current-token"
        })
    }

    func testSuccessfulProactiveRefreshDoesNotRetryCurrentTokenAfterProbeFailure() async {
        let currentAuth = #"{"https://auth.x.ai::client":{"key":"current-token","refresh_token":"refresh","expires_at":"2026-02-02T00:02:00.000Z"}}"#
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.creditsConfigURL {
                throw URLError(.notConnectedToInternet)
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: currentAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(
            http.requests
                .filter { $0.url == GrokUsageClient.creditsConfigURL }
                .compactMap { $0.headers["Authorization"] },
            ["Bearer new-token"],
            "a successful refresh must not turn a probe failure into a retry with the replaced token"
        )
    }

    func testRejectedUnexpiredAccountFallsThroughToNextStoredAccount() async {
        let auth = twoAccountAuth
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL,
               request.headers["Authorization"] == "Bearer stale-token" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: auth).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.lines.first { $0.label == "Weekly limit" })
        XCTAssertEqual(
            http.requests
                .filter { $0.url == GrokUsageClient.creditsConfigURL }
                .compactMap { $0.headers["Authorization"] },
            ["Bearer stale-token", "Bearer valid-token"]
        )
        XCTAssertFalse(http.requests.contains { $0.url == GrokUsageClient.refreshURL })
    }

    func testEveryRejectedAccountReportsExpiredAfterTryingAllAccounts() async {
        let http = RefreshHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            }
            return Self.defaultRoute(request)
        }

        let snapshot = await makeProvider(http: http, authJSON: twoAccountAuth).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(errorText(snapshot), GrokAuthError.expired.localizedDescription)
        XCTAssertEqual(
            http.requests
                .filter { $0.url == GrokUsageClient.creditsConfigURL }
                .compactMap { $0.headers["Authorization"] },
            ["Bearer stale-token", "Bearer valid-token"]
        )
    }

    private var twoAccountAuth: String {
        """
        {
          "a-stale": {
            "key": "stale-token",
            "expires_at": "2026-07-01T00:00:00.000Z"
          },
          "b-valid": {
            "key": "valid-token",
            "expires_at": "2026-07-01T00:00:00.000Z"
          }
        }
        """
    }

    private func makeProvider(
        http: RefreshHTTPClient,
        authJSON: String = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
    ) -> GrokProvider {
        makeProvider(http: http, files: FakeFiles([GrokAuthStore.authPath: authJSON]))
    }

    private func makeProvider(http: RefreshHTTPClient, files: FakeFiles) -> GrokProvider {
        let fixedNow = now
        return GrokProvider(
            authStore: GrokAuthStore(files: files, now: { fixedNow }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(
                files: FakeFiles(),
                environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/home/none") }
            ),
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )
    }

    private static func defaultRoute(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.creditsConfigURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        if request.url == GrokUsageClient.settingsURL {
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8)
            )
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(let label, let text, _, _) = snapshot.lines.first,
              label == MetricLine.errorBadgeLabel
        else {
            return nil
        }
        return text
    }
}

private final class RefreshHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}
