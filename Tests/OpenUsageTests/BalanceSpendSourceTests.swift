import XCTest
@testable import OpenUsage

/// The two admin-key spend cards (OpenAI, Anthropic). Both read a money amount out of JSON whose type
/// drifts between a number and a decimal string: OpenAI's Costs API now returns `amount.value` as a
/// number, which the string-only decoder rejected — and because the decode failure shared the HTTP
/// guard, the card rendered a bogus "HTTP 200" error instead of the month's spend.
final class BalanceSpendSourceTests: XCTestCase {
    // MARK: - OpenAI

    func testOpenAISumsNumericAmountValues() async {
        let source = openAI(status: 200, body: """
        {"data":[
          {"results":[{"amount":{"currency":"usd","value":0.1215323900000000000000000000}}]},
          {"results":[{"amount":{"currency":"usd","value":2.1376676100000000000000000000}}]},
          {"results":[]}
        ]}
        """)
        let card = await source.load()
        XCTAssertEqual(card.state, .ok)
        XCTAssertEqual(card.primary, BalanceFormat.money(2.2592))
        XCTAssertEqual(card.secondary, "spent this month")
    }

    func testOpenAIStillSumsLegacyStringAmountValues() async {
        let source = openAI(status: 200, body: """
        {"data":[{"results":[{"amount":{"currency":"usd","value":"9.42"}}]}]}
        """)
        let card = await source.load()
        XCTAssertEqual(card.state, .ok)
        XCTAssertEqual(card.primary, BalanceFormat.money(9.42))
    }

    func testOpenAINamesAnUnreadableBodyInsteadOfBlamingTheStatusCode() async {
        let source = openAI(status: 200, body: #"{"data":[{"results":[{"amount":{"value":{"nested":1}}}]}]}"#)
        let card = await source.load()
        guard case .failed(let message) = card.state else {
            return XCTFail("an undecodable 200 must fail, got \(card.state)")
        }
        XCTAssertNotEqual(message, "HTTP 200", "a 200 that didn't decode is a response-shape problem, not an HTTP one")
    }

    func testOpenAIReportsServerErrorStatus() async {
        let card = await openAI(status: 500, body: "nope").load()
        XCTAssertEqual(card.state, .failed("HTTP 500"))
    }

    func testOpenAIDegradesWhenTheKeyIsNotAnAdminKey() async {
        let card = await openAI(status: 401, body: "{}").load()
        XCTAssertEqual(card.state, .unsupported)
    }

    func testOpenAIAsksForAKeyWhenNoneIsConfigured() async {
        var source = OpenAISpendSource()
        source.keyStore = BalanceKeyStore(name: "openai", files: FakeFiles(), environment: FakeEnvironment())
        source.http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let card = await source.load()
        XCTAssertEqual(card.state, .needsKey)
    }

    // MARK: - Anthropic

    func testAnthropicSumsStringCents() async {
        let source = anthropic(status: 200, body: """
        {"data":[{"results":[{"amount":"1400.5"}]},{"results":[{"amount":"16.5"}]}]}
        """)
        let card = await source.load()
        XCTAssertEqual(card.state, .ok)
        XCTAssertEqual(card.primary, BalanceFormat.money(14.17))
    }

    func testAnthropicAlsoSumsNumericCents() async {
        let source = anthropic(status: 200, body: #"{"data":[{"results":[{"amount":1417}]}]}"#)
        let card = await source.load()
        XCTAssertEqual(card.state, .ok)
        XCTAssertEqual(card.primary, BalanceFormat.money(14.17))
    }

    func testAnthropicNamesAnUnreadableBodyInsteadOfBlamingTheStatusCode() async {
        let source = anthropic(status: 200, body: #"{"data":"not-a-list"}"#)
        let card = await source.load()
        guard case .failed(let message) = card.state else {
            return XCTFail("an undecodable 200 must fail, got \(card.state)")
        }
        XCTAssertNotEqual(message, "HTTP 200")
    }

    // MARK: - Helpers

    private func openAI(status: Int, body: String) -> OpenAISpendSource {
        var source = OpenAISpendSource()
        source.keyStore = keyStore(name: "openai", key: "sk-admin-test")
        source.http = FakeHTTPClient(response: response(status: status, body: body))
        return source
    }

    private func anthropic(status: Int, body: String) -> AnthropicSpendSource {
        var source = AnthropicSpendSource()
        source.keyStore = keyStore(name: "anthropic", key: "sk-ant-admin01-test")
        source.http = FakeHTTPClient(response: response(status: status, body: body))
        return source
    }

    private func keyStore(name: String, key: String) -> BalanceKeyStore {
        BalanceKeyStore(
            name: name,
            files: FakeFiles(["~/.config/openusage/\(name).json": #"{"apiKey":"\#(key)"}"#]),
            environment: FakeEnvironment()
        )
    }

    private func response(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }
}
