import SwiftUI

/// A desktop card for one API balance / billing figure. Renders the value when available, an honest
/// muted note when the provider has no API for it, an "Add key" affordance when a key is missing, or a
/// short amber note on failure.
struct BalanceCardView: View {
    let card: BalanceCard
    // @MainActor function type: callers pass MainActor-isolated View methods (e.g.
    // DesktopDashboardView.revealConfigFolder); a non-isolated `(() -> Void)?` can't store those in
    // Swift 6 mode, and the solver surfaces that as "ambiguous use of 'init'" at the enclosing view.
    var onAddKey: (@MainActor () -> Void)? = nil

    private var accent: Color { Color(hexString: card.accentHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .desktopCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: card.iconSystemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(card.title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let link = card.link {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch card.state {
        case .ok:
            VStack(alignment: .leading, spacing: 4) {
                Text(card.primary ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let secondary = card.secondary {
                    Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let progress = card.progress {
                    MeterBar(fraction: progress, tint: accent).padding(.top, 2)
                }
                if let detail = card.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        case .needsKey:
            VStack(alignment: .leading, spacing: 7) {
                if let detail = card.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onAddKey {
                    Button(action: onAddKey) {
                        Text("Set up…").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(accent)
                }
            }
            .padding(.top, 2)
        case .unsupported:
            VStack(alignment: .leading, spacing: 3) {
                Text("Not available via API")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if let detail = card.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 3) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = card.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        }
    }
}
