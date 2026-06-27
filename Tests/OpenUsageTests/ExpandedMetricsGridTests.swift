import SwiftUI
import XCTest
@testable import OpenUsage

/// Unit coverage for the pure column-count rule behind the dashboard's expanded-metrics grid
/// (exploration for #596). The grid lays the "Shown on Expand" metrics up to three across, but the
/// number of columns depends on how many metrics there are and whether any are too wide (bounded
/// meters / charts) to read three-up at the popover's ~292pt card width.
final class ExpandedMetricsGridTests: XCTestCase {
    func testSingleMetricIsAlwaysOneColumn() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 1, hasWideMetric: false), 1)
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 1, hasWideMetric: true), 1)
    }

    func testNarrowMetricsFillUpToThreeAcross() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 2, hasWideMetric: false), 2)
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 3, hasWideMetric: false), 3)
    }

    func testNarrowMetricsNeverExceedThreeColumns() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 4, hasWideMetric: false), 3)
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 9, hasWideMetric: false), 3)
    }

    func testWideMetricsCapAtTwoColumns() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 2, hasWideMetric: true), 2)
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 3, hasWideMetric: true), 2)
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 5, hasWideMetric: true), 2)
    }

    func testEmptyOrZeroDegradesToSingleColumn() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.columnCount(metricCount: 0, hasWideMetric: false), 1)
    }

    func testMaxColumnsCeilingIsThree() {
        XCTAssertEqual(ExpandedMetricsGrid<EmptyView>.maxColumns, 3)
    }
}
