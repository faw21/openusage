import SwiftUI

/// The branded, off-screen PNG for the Total Spend card's share action — the aggregate counterpart to
/// `ShareCardView`. Static: the period title is baked into the header (no segmented control in an
/// image), and the body reuses `TotalSpendRingContent` so the exported ring and legend are exactly
/// what the popover shows. Same authored width, opaque tray background, forced appearance, and
/// watermark footer as the per-provider card, so shared images read as one family.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let appearance: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            DashboardMetricCard {
                TotalSpendRingContent(total: total)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            footer
        }
        .padding(16)
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .background(Theme.traySurface)
        .environment(\.colorScheme, appearance)
        // ImageRenderer can't draw the tooltips' AppKit anchor views — without this, each anchor
        // rasterizes as a yellow placeholder box over the card (e.g. on the ring's center total).
        .environment(\.hoverTooltipsDisabled, true)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Total Spend")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(total.period.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ProviderIcon(source: .providerMark("openusage"), inset: 0)
                .frame(width: 14, height: 14)
            Text("Monitor Your AI Subscriptions with OpenUsage")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
