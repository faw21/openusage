import SwiftUI
import AppKit

/// Central palette + surface styles. Surfaces stay adaptive (light/dark).
///
/// The popover is always a solid, opaque panel — Liquid Glass is reserved for the footer's chrome
/// controls, never the data region behind them (Apple's guidance: glass for navigation/controls,
/// content on an opaque surface). So the data surfaces here are plain opaque fills: a light-gray
/// window "tray" with white grouped cards in light mode, a near-black tray with a step-lighter card
/// in dark mode — the System Settings grouped-box look.
enum Theme {
    /// Hierarchical secondary tint for the provider marks.
    static let iconGray = AnyShapeStyle(.secondary)

    /// Meter fill for a severity band — the macOS system palette (the battery-style traffic light),
    /// never hand-tuned hexes, so the bars track light/dark and accessibility settings like every
    /// other system meter. Full strength: on the opaque surface there's no glass to temper against.
    static func meterFill(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        AnyShapeStyle(meterColor(severity))
    }

    private static func meterColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// Inline notice/alert tint (refresh warning triangle, pin-limit notice, settings errors) — the
    /// system orange at full strength, matching the meter fills.
    static let notice = AnyShapeStyle(Color(nsColor: .systemOrange))

    // MARK: - Surfaces

    /// The popover's opaque backdrop ("tray") behind the grouped cards. Deliberately a touch grayer
    /// than pure white in light mode so the white cards read as raised boxes on it — the System
    /// Settings look (`windowBackgroundColor` is too near-white for white cards to separate). A
    /// near-black in dark mode. Exposed as an `NSColor` so the panel's AppKit backdrop
    /// (`StatusItemController`) and the SwiftUI surface (`DashboardView.PopoverSurface`) are one color.
    static let trayNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.12, alpha: 1)
            : NSColor(white: 0.93, alpha: 1)
    }
    static let traySurface = Color(nsColor: trayNSColor)

    /// The opaque grouped-card color, shared by the live card fill and the lifted drag preview so a
    /// dragged card is the exact same color as the cards it floats over. White over the gray tray in
    /// light mode, a step lighter than the near-black tray in dark mode (no stock semantic color lifts
    /// above the window background in dark, so the dark value is set explicitly); the hairline
    /// `cardBorder` crisps the edge in both modes.
    static let cardNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.19, alpha: 1)
            : NSColor.white
    }
    static let cardFill = AnyShapeStyle(Color(nsColor: cardNSColor))

    /// Backing for lifted drag previews — the SAME opaque color as the live cards, so a dragged card
    /// matches the cards it floats over (it was a translucent material before, which read as a
    /// different color). The "lifted" feel comes from `ReorderLiftPreview`'s shadow + scale, not the fill.
    static let liftedCardFill = AnyShapeStyle(Color(nsColor: cardNSColor))

    /// Hairline outline on cards. The opaque fill separates cards well in light mode but barely in
    /// dark mode (the card sits only a step above the tray there), so a defined edge carries the
    /// separation deterministically in both — the way macOS grouped boxes (System Settings) read.
    /// `.separator` is the semantic hairline, so it tracks light/dark and Increase Contrast.
    static let cardBorder = AnyShapeStyle(.separator)

    /// The single corner radius for every metric/settings card surface and its lifted twin, so the
    /// floating drag preview always matches the live card's shape.
    static let cardCornerRadius: CGFloat = 12

    /// The rounded rectangle shared by every card surface (live and lifted), so the shape is defined once.
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// The grouped-card surface used for provider/settings cards, in the shared rounded shape: an
    /// opaque fill plus a hairline border so each card reads as a distinct raised box on the popover
    /// tray (the border carries that separation in dark mode). Pass `lifted: true` for the floating
    /// drag preview, which swaps the fill for the heavier lifted material and skips the border (its
    /// shadow/`liftedRowSurface` hairline already detaches it). Routing every card site through this
    /// keeps the live card and its lifted twin one shape.
    func cardSurface(lifted: Bool = false) -> some View {
        modifier(CardSurfaceModifier(lifted: lifted))
    }

    /// A single-row lifted preview surface: the card fill plus the thin separator hairline that
    /// fences a free-floating one-row chip off from the rows beneath it (the multi-row provider
    /// previews don't take the hairline — the card outline alone reads as detached there).
    func liftedRowSurface() -> some View {
        cardSurface(lifted: true)
            .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// The trailing on/off switch styling shared by every settings + Customize row toggle: no inline
    /// label (the row's leading text is the label), the native switch style, small control size.
    func settingsSwitchStyle() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// Backs `cardSurface`. Live cards take the opaque card fill plus the hairline border so they stay
/// distinct boxes on the opaque popover tray (the border carries the separation in dark mode). The
/// lifted drag preview always uses its own legible material and no border.
private struct CardSurfaceModifier: ViewModifier {
    let lifted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if lifted {
            content.background(Theme.liftedCardFill, in: Theme.cardShape)
        } else {
            content
                .background(Theme.cardFill, in: Theme.cardShape)
                .overlay { Theme.cardShape.strokeBorder(Theme.cardBorder, lineWidth: 0.5) }
        }
    }
}
