import Foundation
import XCTest
@testable import OpenUsageCLI

final class TerminalRendererTests: XCTestCase {
    func testRendersProgressTextAndPlan() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.date(from: "2026-07-12T10:00:00.000Z")!
        let snapshot = UsageSnapshot(
            providerId: "claude",
            displayName: "Claude",
            plan: "Pro",
            lines: [
                UsageLine(type: "progress", label: "Session", used: 42, limit: 100,
                          format: .init(kind: "percent"), resetsAt: "2026-07-12T12:00:00.000Z"),
                UsageLine(type: "text", label: "Today", value: "$5.17 · 9.2M tokens")
            ],
            fetchedAt: "2026-07-12T09:55:00.000Z"
        )

        XCTAssertEqual(TerminalRenderer.render([snapshot], now: now), """
        Claude (Pro)
          Session: 42% used · resets in 2h
          Today: $5.17 · 9.2M tokens
          Updated: 5m ago
        """)
    }
}
