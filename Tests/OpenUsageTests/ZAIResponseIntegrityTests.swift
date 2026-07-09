import XCTest
@testable import OpenUsage

final class ZAIResponseIntegrityMapperTests: XCTestCase {
    func testMalformedJSONThrowsInvalidResponse() {
        assertInvalidQuota(Data("<html>gateway response</html>".utf8))
    }

    func testWrongTopLevelAndEnvelopeShapesThrowInvalidResponse() {
        let wrongShapes = [
            "[]",
            #"{"success":1,"data":{"limits":[]}}"#,
            #"{"success":true}"#,
            #"{"success":true,"data":[]}"#,
            #"{"success":true,"data":{}}"#,
            #"{"success":true,"data":{"limits":{}}}"#,
            #"{"success":true,"data":{"limits":[{"type":"UNKNOWN_LIMIT"}]}}"#
        ]

        for body in wrongShapes {
            assertInvalidQuota(Data(body.utf8), context: body)
        }
    }

    func testRecognizedLimitsMissingRequiredNumbersThrowInsteadOfFabricatingZero() {
        let missingFields = [
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","number":5,"percentage":10}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":true,"usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10,"usage":-1}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10,"nextResetTime":"later"}]}}"#
        ]

        for body in missingFields {
            assertInvalidQuota(Data(body.utf8), context: body)
        }
    }

    private func assertInvalidQuota(
        _ body: Data,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body), context, file: file, line: line) { error in
            XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, context, file: file, line: line)
        }
    }
}

@MainActor
final class ZAIResponseIntegrityProviderTests: XCTestCase {
    func testMalformedQuotaJSONReportsDecodingFailure() async {
        let snapshot = await makeProvider(quotaBody: Data("not-json".utf8)).refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertEqual(errorText(snapshot), "Usage response invalid. Try again later.")
    }

    func testWrongQuotaShapeReportsDecodingFailure() async {
        let snapshot = await makeProvider(
            quotaBody: Data(#"{"success":true,"data":[]}"#.utf8)
        ).refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testBusinessFailurePreservesEnvelopeCodeAndCategory() async {
        let snapshot = await makeProvider(
            quotaBody: Data(#"{"success":false,"code":500,"msg":"internal error"}"#.utf8)
        ).refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(errorText(snapshot), "Z.ai usage request failed (code 500). Try again later.")
    }

    func testMissingRequiredUsageNumberReportsDecodingInsteadOfZeroUsage() async {
        let snapshot = await makeProvider(
            quotaBody: Data(
                #"{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#.utf8
            )
        ).refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testExplicitlyEmptyLimitsRemainAValidNoUsageDataSnapshot() async {
        let snapshot = await makeProvider(
            quotaBody: Data(#"{"success":true,"data":{"limits":[]}}"#.utf8)
        ).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))
        XCTAssertNotNil(snapshot.line(label: "Status"))
    }

    private func makeProvider(quotaBody: Data) -> ZAIProvider {
        ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: quotaBody)
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"success":true,"data":[]}"#.utf8)
                )
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func errorText(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
        return text
    }
}
