import Foundation

/// Webshare proxy bandwidth: ACTUAL bytes used this cycle + the reset date. `bandwidth_total` from the
/// stats aggregate is the actual usage (not the `bandwidth_projected` estimate). Webshare's dashboard
/// renders bytes in BINARY units (it labels TiB/GiB "TB"/"GB"), so we match with `BalanceFormat.bandwidth`
/// (÷1024) — a decimal ÷1000 conversion reads ~10% high and looks like the projection. The active plan's
/// `bandwidth_limit` (GB; 0 == unlimited) lives in /subscription/plan/'s results list.
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
            let subscription = try await get(endpoint("subscription/"), key)
            if subscription.statusCode == 401 { return card(.failed("Invalid key")) }
            guard subscription.statusCode == 200 else { return card(.failed("HTTP \(subscription.statusCode)")) }
            let subscriptionData = try? JSONDecoder().decode(Subscription.self, from: subscription.body)
            let startISO = subscriptionData?.start_date
            let resetDate = subscriptionData?.end_date

            // Active plan's bandwidth limit (GB); 0 == unlimited.
            var limitGB: Double = 0
            if let plans = try? await get(endpoint("subscription/plan/"), key), plans.statusCode == 200,
               let planList = try? JSONDecoder().decode(PlanList.self, from: plans.body),
               let active = planList.results.first(where: { $0.status == "active" }) ?? planList.results.first {
                limitGB = active.bandwidth_limit ?? 0
            }

            // Actual bytes used this cycle (bandwidth_total, not bandwidth_projected).
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

            let used = BalanceFormat.bandwidth(bytes: usedBytes)
            let detail = resetDate.map { "Resets \(BalanceFormat.day($0))" }
            if limitGB > 0 {
                let limitBytes = limitGB * 1_073_741_824   // treat the plan's GB as GiB to match the dashboard
                let progress = min(1, usedBytes / limitBytes)
                return card(.ok,
                            primary: "\(used) / \(BalanceFormat.bandwidth(bytes: limitBytes))",
                            secondary: "\(Int((progress * 100).rounded()))% of plan bandwidth",
                            detail: detail, progress: progress, updatedAt: Date())
            }
            return card(.ok, primary: used, secondary: "Unlimited plan", detail: detail, updatedAt: Date())
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

    private struct PlanList: Decodable { let results: [PlanEntry] }
    private struct PlanEntry: Decodable {
        let status: String?
        let bandwidth_limit: Double?
    }
    private struct Subscription: Decodable {
        let start_date: String?
        let end_date: String?
    }
    private struct Stats: Decodable { let bandwidth_total: Double? }
}
