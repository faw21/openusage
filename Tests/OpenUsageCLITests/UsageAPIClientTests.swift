import Foundation
import XCTest
@testable import OpenUsageCLI

final class UsageAPIClientTests: XCTestCase {
    func testConnectionRefusalMeansAppUnavailable() {
        XCTAssertEqual(
            UsageAPIClient.classifyTransportError(URLError(.cannotConnectToHost)),
            .appUnavailable
        )
    }

    func testOtherTransportFailuresRemainRequestErrors() {
        let error = UsageAPIClient.classifyTransportError(URLError(.timedOut))
        guard case .request(let message) = error else {
            return XCTFail("Expected timeout to remain a request error, got \(error)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testChartPointWithoutValueLabelDecodesAndRendersValue() throws {
        let data = Data(#"""
        [{
          "providerId": "claude",
          "displayName": "Claude",
          "lines": [{
            "type": "barChart",
            "label": "Usage Trend",
            "points": [{"label": "Jul 12", "value": 1200}]
          }],
          "fetchedAt": "2026-07-12T08:00:00.000Z"
        }]
        """#.utf8)

        let snapshots = try JSONDecoder().decode([UsageSnapshot].self, from: data)

        XCTAssertNil(snapshots[0].lines[0].points?[0].valueLabel)
        XCTAssertTrue(TerminalRenderer.render(snapshots).contains("1.2K tokens"))
    }
}
