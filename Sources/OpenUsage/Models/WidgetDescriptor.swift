import Foundation

/// A provider metric's identity and presentation template. Live provider lines supply the values;
/// `sample` carries stable display metadata such as title, icon, kind, and descriptor opt-ins.
struct WidgetDescriptor: Identifiable, Hashable {
    let id: String                 // "claude.session"
    let providerID: String
    let metricLabel: String
    let sample: WidgetData
    /// Whether this widget can be pinned to the menu-bar strip. False for tiles the tray can't render as
    /// a value — the Usage Trend chart — so the pin affordance never offers a pin that would read "0".
    var pinnable: Bool = true
    /// True only for the `SpendTileMapper`-backed spend-history tiles (see `WidgetDescriptor.spendTiles`).
    /// The Total Spend card keys on this to decide which providers feed the ring — a title match would
    /// wrongly rope in look-alike rows like OpenRouter's API-spend "Today".
    var isSpendTile: Bool = false
    /// True for usage metrics sourced from the provider's account (server-side exports like Cursor's
    /// usage CSV) rather than this machine's local logs. Nearby-Mac sync must never merge these:
    /// every Mac signed in to the same account reports the identical numbers, so adding them
    /// double-counts. Machine-local metrics (Claude/Codex/Grok log scans) stay additive.
    var isAccountWideUsage: Bool = false

    /// The metric's single display name.
    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
