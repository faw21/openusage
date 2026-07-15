import Foundation

/// Webshare proxy bandwidth: used vs. plan limit and the cycle reset date. Three v2 REST calls with a
/// static `Authorization: Token <key>` header (no OAuth). Key from ~/.config/openusage/webshare.json.
/// `bandwidth_limit` is in GB; `bandwidth_total` is in bytes — converted before comparing.
struct WebshareSource: BalanceSource {
    let id = "webshare"
    let title = "Webshare"
    let iconSystemName = "network"
    let accentHex = "#16A34A"
    let link = URL(string: "https://dashboard.webshare.io/")

    var keyStore = BalanceKeyStore(name: "webshare", environmentNames: ["WEBSHARE_API_KEY", "WEBSHARE_KEY"])
    var http: any HTTPClient = URLSessionHTTPClient()

    func load() async -> BalanceCard {
        guard let key = keyStore.key() else {
            return card(.needsKey, detail: "Add your Webshare API key")
        }
        do {
            let plan = try await get(endpoint("subscription/plan/"), key)
            if plan.statusCode == 401 { return card(.failed("Invalid key")) }
            guard plan.statusCode == 200 else { return card(.failed("HTTP \(plan.statusCode)")) }
            let planData = try? JSONDecoder().decode(Plan.self, from: plan.body)
            let limitGB = planData?.bandwidth_limit ?? 0   // GB; 0 == unlimited

            let subscription = try? await get(endpoint("subscription/"), key)
            let subscriptionData = subscription.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0.body) }
            let startISO = subscriptionData?.start_date
            let resetDate = subscriptionData?.end_date

            var usedBytes: Double = 0
            if let startISO {
                var components = URLComponents(string: "https://proxy.webshare.io/api/v2/stats/aggregate/")!
                components.queryItems = [URLQueryItem(name: "timestamp__gte", value: startISO)]
                if let statsURL = components.url,
                   let stats = try? await get(statsURL, key), stats.statusCode == 200,
                   let statsData = try? JSONDecoder().decode(Stats.self, from: stats.body) {
                    usedBytes = statsData.bandwidth_total ?? 0
                }
            }

            let usedGB = usedBytes / 1_000_000_000
            let progress = limitGB > 0 ? min(1, usedGB / limitGB) : nil
            let primary = limitGB > 0
                ? "\(BalanceFormat.gb(usedGB)) / \(BalanceFormat.gb(limitGB))"
                : BalanceFormat.gb(usedGB)
            let secondary = limitGB > 0
                ? "\(Int(((progress ?? 0) * 100).rounded()))% of plan bandwidth"
                : "Unlimited plan"
            let detail = resetDate.map { "Resets \(BalanceFormat.day($0))" }
            return card(.ok, primary: primary, secondary: secondary, detail: detail,
                        progress: progress, updatedAt: Date())
        } catch {
            return card(.failed("Couldn't reach Webshare"))
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: "https://proxy.webshare.io/api/v2/\(path)")!
    }

    private func get(_ url: URL, _ key: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET", url: url,
            headers: ["Authorization": "Token \(key)", "Accept": "application/json"], timeout: 15))
    }

    private struct Plan: Decodable { let bandwidth_limit: Double? }
    private struct Subscription: Decodable {
        let start_date: String?
        let end_date: String?
    }
    private struct Stats: Decodable { let bandwidth_total: Double? }
}
