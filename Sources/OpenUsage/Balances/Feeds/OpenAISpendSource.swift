import Foundation

/// OpenAI exposes no prepaid balance for a key. Month-to-date spend is available via the Costs API, which
/// requires an admin key (`sk-admin-…`). We query it; a non-admin key (401/403) degrades to an honest
/// "not available" rather than a red error.
struct OpenAISpendSource: BalanceSource {
    let id = "openai"
    let title = "OpenAI"
    let iconSystemName = "cpu"
    let accentHex = "#10A37F"
    let link = URL(string: "https://platform.openai.com/usage")

    var keyStore = BalanceKeyStore(name: "openai", environmentNames: ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"])
    var http: any HTTPClient = URLSessionHTTPClient()

    func load() async -> BalanceCard {
        guard let key = keyStore.key() else {
            return card(.needsKey, detail: "Add an OpenAI admin key for month-to-date spend")
        }
        let start = BalanceFormat.startOfMonthUnix()
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        guard let url = components.url else { return card(.unsupported) }
        do {
            let response = try await http.send(HTTPRequest(
                method: "GET", url: url,
                headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], timeout: 20))
            if response.statusCode == 401 || response.statusCode == 403 {
                return card(.unsupported, detail: "No balance API · spend needs an admin key")
            }
            guard response.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(Costs.self, from: response.body) else {
                return card(.failed("HTTP \(response.statusCode)"))
            }
            // `amount.value` is a decimal USD string (high precision), not a number.
            let total = parsed.data.flatMap { $0.results }.compactMap { $0.amount?.value }.compactMap(Double.init).reduce(0, +)
            return card(.ok, primary: BalanceFormat.money(total), secondary: "spent this month",
                        detail: "API keys have no prepaid balance", updatedAt: Date())
        } catch {
            return card(.failed("Couldn't reach OpenAI"))
        }
    }

    private struct Costs: Decodable { let data: [Bucket] }
    private struct Bucket: Decodable { let results: [Result] }
    private struct Result: Decodable { let amount: Amount? }
    private struct Amount: Decodable { let value: String? }
}
