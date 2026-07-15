import SwiftUI
import AppKit

/// The desktop widget's root view: a header with live refresh, an "AI Coding" section (Claude Code +
/// Codex, from the shared `WidgetDataStore`), and an "API Balances & Billing" grid (from `BalanceStore`).
/// Sized for the floating panel; content scrolls when it overflows.
struct DesktopDashboardView: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(BalanceStore.self) private var balances

    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    codingSection
                    balancesSection
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 660)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var codingSection: some View {
        section("AI Coding") {
            HStack(alignment: .top, spacing: 12) {
                CodingUsageCardView(
                    title: "Claude Code", iconSystemName: "a.circle.fill", accentHex: "#D97757",
                    snapshot: dataStore.snapshots["claude"], error: dataStore.providerErrors["claude"]
                )
                CodingUsageCardView(
                    title: "Codex", iconSystemName: "chevron.left.forwardslash.chevron.right",
                    accentHex: "#10A37F",
                    snapshot: dataStore.snapshots["codex"], error: dataStore.providerErrors["codex"]
                )
            }
        }
    }

    private var balancesSection: some View {
        section("API Balances & Billing") {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(balances.cards) { card in
                    BalanceCardView(card: card, onAddKey: addKeyAction(for: card))
                }
            }
        }
    }

    /// The `needsKey` cards' setup action, isolated so the grid closure stays trivial to type-check.
    private func addKeyAction(for card: BalanceCard) -> (@MainActor () -> Void)? {
        guard card.isActionable else { return nil }
        return { @MainActor in Self.revealConfigFolder() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemBlue))
            VStack(alignment: .leading, spacing: 0) {
                Text("OpenUsage").font(.system(size: 15, weight: .bold))
                Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            headerButton("arrow.clockwise", help: "Refresh now") {
                let balances = balances
                let dataStore = dataStore
                Task { @MainActor in
                    async let balanceRefresh: Void = balances.refreshAll()
                    await dataStore.refreshAll()
                    await balanceRefresh
                }
            }
            if let onTogglePin {
                headerButton("pin", help: "Keep on top", action: onTogglePin)
            }
            if let onClose {
                headerButton("xmark", help: "Hide widget", action: onClose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusText: String {
        if balances.isRefreshing || !dataStore.refreshingProviderIDs.isEmpty { return "Refreshing…" }
        if let date = balances.lastRefreshedAt {
            return "Updated \(date.formatted(date: .omitted, time: .shortened)) · local only"
        }
        return "Local only · nothing leaves your Mac"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }

    @MainActor
    private static func revealConfigFolder() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/openusage")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
