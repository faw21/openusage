import Foundation

/// GCP current-month spend. No API-key path exists; the only reliable figure comes from a BigQuery
/// billing export. If the user points us at their export table (`~/.config/openusage/gcp.json`), we run a
/// `bq` query for the net current-month cost; otherwise we show an honest "set up" card. Refreshed every
/// few hours — billing data lags up to a day and barely moves, and the scan is trivially within
/// BigQuery's free tier, so a tighter cadence would just re-read the same number.
struct GCPBillingSource: BalanceSource {
    let id = "gcp"
    let title = "Google Cloud"
    let iconSystemName = "cloud"
    let accentHex = "#4285F4"
    let link = URL(string: "https://console.cloud.google.com/billing")
    var refreshInterval: TimeInterval { 6 * 3600 }

    var runner: ProcessRunning = SystemProcessRunner()

    func load() async -> BalanceCard {
        let config = GCPBillingConfig.load()
        guard let table = config.bqTable, !table.isEmpty else {
            return card(.needsKey, detail: "Point me at your BigQuery billing export table")
        }
        guard let bq = config.resolveBQ() else {
            return card(.failed("bq CLI not found — install Google Cloud SDK"))
        }
        // Net cost = raw cost + credits (credits are stored negative), for the current invoice month.
        let sql = """
        SELECT SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)) AS net \
        FROM `\(table)` \
        WHERE invoice.month = FORMAT_DATE('%Y%m', CURRENT_DATE())
        """
        let environment = GCPBillingConfig.childEnvironment()
        let runner = self.runner
        do {
            let result = try await Task.detached(priority: .utility) {
                try runner.run(
                    executable: bq,
                    arguments: ["query", "--nouse_legacy_sql", "--format=json", "--quiet", sql],
                    environment: environment,
                    timeout: 45
                )
            }.value
            guard result.succeeded else {
                return card(.failed(Self.diagnose(result.stderr)))
            }
            guard let value = Self.parseNet(result.stdout) else {
                return card(.ok, primary: BalanceFormat.money(0), secondary: "spent this month",
                            detail: "No billing rows yet this month", updatedAt: Date())
            }
            return card(.ok, primary: BalanceFormat.money(value), secondary: "spent this month",
                        detail: "BigQuery export · updates a few times/day", updatedAt: Date())
        } catch {
            return card(.failed("bq query timed out"))
        }
    }

    /// Turn a `bq` stderr blob into a short, actionable hint.
    static func diagnose(_ stderr: String) -> String {
        if stderr.contains("Not found") { return "Export table not found — check the name" }
        if stderr.localizedCaseInsensitiveContains("credential") || stderr.localizedCaseInsensitiveContains("auth") {
            return "Run: gcloud auth application-default login"
        }
        return "bq query failed"
    }

    /// `bq ... --format=json` prints an array of row objects; the single row's `net` field may be a
    /// number, a numeric string, or null when there are no rows yet.
    static func parseNet(_ stdout: String) -> Double? {
        guard let data = stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else { return nil }
        if let number = first["net"] as? NSNumber { return number.doubleValue }
        if let string = first["net"] as? String { return Double(string) }
        return nil
    }
}
