import Foundation

/// Anthropic exposes no prepaid balance for a key. Org-level month-to-date spend comes from the Cost
/// Report Admin API, which requires an admin key (`sk-ant-admin01-…`). `amount` is a decimal amount in
/// CENTS, shipped as a string (a number also decodes — see `LooseNumber`). A non-admin key (401/403)
/// degrades to an honest "not available".
struct AnthropicSpendSource: BalanceSource {
    let id = "anthropic"
    let title = "Anthropic"
    let iconSystemName = "a.circle"
    let accentHex = "#D97757"
    let link = URL(string: "https://console.anthropic.com/settings/usage")

    var keyStore = BalanceKeyStore(name: "anthropic", environmentNames: ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_API_KEY"])
    var http: any HTTPClient = URLSessionHTTPClient()

    func load() async -> BalanceCard {
        guard let key = keyStore.key() else {
            return card(.needsKey, detail: "Add an Anthropic admin key for month-to-date spend")
        }
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: BalanceFormat.startOfMonthISO()),
            URLQueryItem(name: "ending_at", value: BalanceFormat.nowISO()),
            URLQueryItem(name: "bucket_width", value: "1d"),
            // One page for a whole month of daily buckets — the default page size is smaller and would
            // otherwise return a partial month (which read as an inflated total before the /100 below).
            URLQueryItem(name: "limit", value: "31")
        ]
        guard let url = components.url else { return card(.unsupported) }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET", url: url,
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "Accept": "application/json"
                ], timeout: 20))
        } catch {
            AppLog.error(.http, "anthropic cost report request failed: \(error.localizedDescription)")
            return card(.failed("Couldn't reach Anthropic"))
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return card(.unsupported, detail: "No balance API · spend needs an admin key")
        }
        guard response.statusCode == 200 else {
            AppLog.error(.http, "anthropic cost report HTTP \(response.statusCode)")
            return card(.failed("HTTP \(response.statusCode)"))
        }
        do {
            let parsed = try JSONDecoder().decode(Report.self, from: response.body)
            // `amount` is in CENTS (verified against the live account: raw month sum ~1417 → $14.17).
            // Sum, then convert to dollars.
            let cents = parsed.data.flatMap { $0.results }.compactMap { $0.amount?.double }.reduce(0, +)
            return card(.ok, primary: BalanceFormat.money(cents / 100), secondary: "spent this month",
                        detail: "API keys have no prepaid balance", updatedAt: Date())
        } catch {
            AppLog.error(.http, "anthropic cost report didn't decode: \(error)")
            return card(.failed("Unexpected response"))
        }
    }

    private struct Report: Decodable { let data: [Bucket] }
    private struct Bucket: Decodable { let results: [Result] }
    private struct Result: Decodable { let amount: LooseNumber? }
}
