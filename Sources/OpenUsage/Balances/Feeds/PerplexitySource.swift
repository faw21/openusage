import Foundation

/// Perplexity balance/spend. As of this build no public API returns account balance or month-to-date
/// spend for a standard key — credits live only in the web console — so this shows an honest, non-error
/// "not available" card. Isolated here so that if a billing/admin endpoint is confirmed, only this file
/// changes: swap the body for a real fetch keyed off `~/.config/openusage/perplexity.json`.
struct PerplexitySource: BalanceSource {
    let id = "perplexity"
    let title = "Perplexity"
    let iconSystemName = "magnifyingglass"
    let accentHex = "#20B8CD"
    let link = URL(string: "https://www.perplexity.ai/account/api/group")

    func load() async -> BalanceCard {
        card(.unsupported, detail: "No balance API — credits shown in the console")
    }
}
