import Foundation

/// A single balance/billing lookup for the desktop widget. Each source owns its own key lookup, HTTP
/// call, and graceful degradation, and returns a fully-rendered `BalanceCard`. Sources are stateless
/// value types (Sendable) so `BalanceStore` can fan them out concurrently off the main actor.
protocol BalanceSource: Sendable {
    var id: String { get }
    var title: String { get }
    var iconSystemName: String { get }
    var accentHex: String { get }
    var link: URL? { get }
    /// How often `BalanceStore` should reload this source. Fast providers use the default few minutes;
    /// GCP overrides to hours because billing data barely moves (and to keep BigQuery reads trivial).
    var refreshInterval: TimeInterval { get }
    /// Whether the widget's manual refresh button reloads this source. GCP opts out — its data barely
    /// moves and each reload spawns a `bq` subprocess — so it refreshes only on its own timer.
    var refreshesOnManual: Bool { get }

    /// Never throws — a source maps every failure onto a `BalanceCard` state so one bad provider can't
    /// take down the whole row. Runs off the main actor.
    func load() async -> BalanceCard
}

extension BalanceSource {
    var link: URL? { nil }
    var refreshInterval: TimeInterval { 300 }
    var refreshesOnManual: Bool { true }

    /// Build a card pre-filled with this source's identity, so each source body stays about the data.
    func card(
        _ state: BalanceCard.State,
        primary: String? = nil,
        secondary: String? = nil,
        detail: String? = nil,
        progress: Double? = nil,
        updatedAt: Date? = nil
    ) -> BalanceCard {
        BalanceCard(
            id: id,
            title: title,
            iconSystemName: iconSystemName,
            accentHex: accentHex,
            link: link,
            state: state,
            primary: primary,
            secondary: secondary,
            detail: detail,
            progress: progress,
            updatedAt: updatedAt
        )
    }
}
