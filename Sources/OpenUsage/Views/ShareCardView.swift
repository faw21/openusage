import SwiftUI

/// An off-screen, branded 16:9 card of one provider's usage, rendered to a PNG for the right-click
/// "Share" action. It is a static snapshot — no drag grips, spinners, staleness tags, or refresh
/// warnings — so the exported image reads as a clean, shareable summary rather than a screenshot of
/// the live, interactive dashboard.
///
/// The view takes already-resolved `[WidgetData]` (not a store), so it has no environment dependency
/// and is rendered the same way in the app and in tests. It paints an explicit opaque
/// `Theme.traySurface` background because an `ImageRenderer` has no window backdrop behind it, and it
/// forces the effective light/dark appearance via `.environment(\.colorScheme, …)` (the rows resolve
/// their colors from the environment, not locally), so a Light-mode user gets a light card even when
/// the OS is in dark mode.
struct ShareCardView: View {
    let provider: Provider
    var plan: String?
    let rows: [WidgetData]
    let appearance: ColorScheme

    /// Fixed 16:9 canvas. The renderer scales this up (×2) for a crisp PNG; the layout itself is
    /// authored at these point dimensions.
    static let width: CGFloat = 1200
    static let height: CGFloat = 675

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            headerRow
            metricsCard
            Spacer(minLength: 0)
            footer
        }
        .padding(48)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Theme.traySurface)
        .environment(\.colorScheme, appearance)
    }

    // MARK: - Header

    /// Provider mark + name (+ optional plan), mirroring the dashboard header but static: no drag
    /// grip, spinner, staleness tag, or warning triangle.
    private var headerRow: some View {
        HStack(spacing: 16) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 44, height: 44)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(provider.displayName)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    /// The provider's visible metric rows in the shared card surface, reusing `WidgetRowView` so the
    /// exported card matches the live dashboard exactly. Toggles are nil (static render). An empty
    /// provider falls back to a quiet placeholder so the card never renders blank.
    @ViewBuilder
    private var metricsCard: some View {
        if rows.isEmpty {
            DashboardMetricCard {
                Text("No metrics to show")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        } else {
            DashboardMetricCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, data in
                    WidgetRowView(data: data)
                }
            }
        }
    }

    // MARK: - Footer

    /// The brand mark + wordmark, anchored bottom-leading. Quiet (secondary) so it reads as a
    /// watermark, not a headline.
    private var footer: some View {
        HStack(spacing: 8) {
            ProviderIcon(source: .providerMark("openusage"), inset: 0)
                .frame(width: 22, height: 22)
            Text("OpenUsage")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
