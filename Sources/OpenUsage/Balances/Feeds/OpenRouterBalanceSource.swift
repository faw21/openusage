import Foundation

/// OpenRouter prepaid credit balance + month-to-date spend, reusing the app's existing OpenRouter client
/// and key store so it lights up from the same key the OpenRouter provider already uses.
struct OpenRouterBalanceSource: BalanceSource {
    let id = "openrouter"
    let title = "OpenRouter"
    let iconSystemName = "arrow.triangle.branch"
    let accentHex = "#8B7CF6"
    let link = URL(string: "https://openrouter.ai/settings/credits")

    var authStore = OpenRouterAuthStore()
    var client = OpenRouterUsageClient()

    func load() async -> BalanceCard {
        guard let key = authStore.currentAPIKey() else {
            return card(.needsKey, detail: "Set OPENROUTER_API_KEY or ~/.config/openusage/openrouter.json")
        }
        do {
            let credits = try await client.fetchCredits(apiKey: key)
            guard credits.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(CreditsEnvelope.self, from: credits.body) else {
                return card(.failed("HTTP \(credits.statusCode)"))
            }
            let balance = parsed.data.total_credits - parsed.data.total_usage

            var monthly: Double?
            if let keyResponse = try? await client.fetchKey(apiKey: key), keyResponse.statusCode == 200,
               let keyParsed = try? JSONDecoder().decode(KeyEnvelope.self, from: keyResponse.body) {
                monthly = keyParsed.data.usage_monthly
            }

            return card(
                .ok,
                primary: BalanceFormat.money(balance),
                secondary: monthly.map { "\(BalanceFormat.money($0)) spent this month" } ?? "credit remaining",
                detail: "\(BalanceFormat.money(parsed.data.total_usage)) used of \(BalanceFormat.money(parsed.data.total_credits))",
                updatedAt: Date()
            )
        } catch {
            return card(.failed("Couldn't reach OpenRouter"))
        }
    }

    private struct CreditsEnvelope: Decodable { let data: Credits }
    private struct Credits: Decodable {
        let total_credits: Double
        let total_usage: Double
    }
    private struct KeyEnvelope: Decodable { let data: KeyData }
    private struct KeyData: Decodable { let usage_monthly: Double? }
}
