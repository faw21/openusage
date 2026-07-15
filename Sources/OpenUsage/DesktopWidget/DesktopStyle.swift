import SwiftUI

extension View {
    /// The frosted, subtly-bordered surface every desktop-widget card sits on. Theme-aware: the fill and
    /// hairline are derived from `.primary`, so they read correctly over the window's material in both
    /// light and dark.
    func desktopCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}
