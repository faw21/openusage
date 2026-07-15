import Foundation

/// One card on the desktop widget's "API Balances & Billing" section: a provider's balance, credit,
/// month-to-date spend, or bandwidth — plus an honest state for the (several) providers whose balance
/// simply is not exposed by any API. Kept deliberately display-oriented (pre-formatted strings) so the
/// view is a dumb renderer, mirroring how the app's spend tiles pass already-priced numbers to the chart.
struct BalanceCard: Identifiable, Sendable, Hashable {
    /// The lifecycle/availability of a card's value. `unsupported` is a first-class, non-error state
    /// because for OpenAI/Anthropic balance, Perplexity, and Gemini the API genuinely returns nothing —
    /// the honest answer is "not available", not a red failure.
    enum State: Sendable, Hashable {
        case loading
        case ok
        case needsKey
        case unsupported
        case failed(String)
    }

    let id: String
    let title: String
    let iconSystemName: String
    let accentHex: String
    var link: URL? = nil

    var state: State = .loading
    /// The headline value, already formatted (e.g. "$42.13", "18.6 / 250 GB").
    var primary: String? = nil
    /// A supporting line (e.g. "$12.40 spent this month").
    var secondary: String? = nil
    /// A third, quieter line (e.g. "Resets Jul 30").
    var detail: String? = nil
    /// 0...1 meter fill when the card represents a bounded resource (bandwidth, a capped key).
    var progress: Double? = nil
    var updatedAt: Date? = nil

    /// A short human label for the non-ok states, used by the view for the muted placeholder row.
    var stateNote: String? {
        switch state {
        case .loading: return "Loading…"
        case .ok: return nil
        case .needsKey: return "Add API key"
        case .unsupported: return "Not available via API"
        case .failed(let message): return message
        }
    }

    var isActionable: Bool {
        switch state {
        case .needsKey: return true
        default: return false
        }
    }
}
