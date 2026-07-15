import SwiftUI

extension Color {
    /// Build a color from a "#RRGGBB" (or "RRGGBB") hex string — the accent format the balance sources
    /// and provider metric lines use. Falls back to a neutral gray on a malformed string.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Color(nsColor: .systemGray)
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
