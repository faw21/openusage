import SwiftUI

/// A thin rounded progress meter, used by both the coding cards and the bounded balance cards
/// (bandwidth). When `tint` is nil it derives a traffic-light color from the fill fraction, matching the
/// app's system-palette meters.
struct MeterBar: View {
    var fraction: Double
    var tint: Color?

    private var clamped: Double { min(max(fraction, 0), 1) }

    private var color: Color {
        if let tint { return tint }
        switch clamped {
        case ..<0.75: return Color(nsColor: .systemBlue)
        case ..<0.9: return Color(nsColor: .systemYellow)
        default: return Color(nsColor: .systemRed)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(3, geometry.size.width * clamped))
            }
        }
        .frame(height: 6)
    }
}
