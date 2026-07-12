import XCTest
@testable import OpenUsage

final class LANUsageAggregatorTests: XCTestCase {
    private let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("test"))

    func testShareableSnapshotsExcludeAccountWideQuota() {
        let registry = makeRegistry()
        let snapshot = makeSnapshot(quota: 42, tokens: 100, dollars: 1.5, chart: 100)

        let shared = LANUsageAggregator.shareableSnapshots(["test": snapshot], registry: registry)

        XCTAssertNil(shared["test"]?.line(label: "Session"))
        XCTAssertNotNil(shared["test"]?.line(label: "Today"))
        XCTAssertNotNil(shared["test"]?.line(label: "Usage Trend"))
        XCTAssertNil(shared["test"]?.plan)
        XCTAssertNil(shared["test"]?.warning)
    }

    func testCombiningPeersSumsOnlyLocalUsageAndKeepsLocalQuota() {
        let registry = makeRegistry()
        let local = makeSnapshot(quota: 42, tokens: 100, dollars: 1.5, chart: 100)
        // The remote quota is included deliberately to prove the aggregator still refuses to merge it.
        let remote = makeSnapshot(quota: 90, tokens: 250, dollars: 3.25, chart: 250)

        let combined = LANUsageAggregator.combinedSnapshots(
            local: ["test": local],
            remotes: ["remote-device": ["test": remote]],
            registry: registry
        )["test"]

        guard let quotaLine = combined?.line(label: "Session"),
              case .progress(_, let used, _, _, _, _, _) = quotaLine else {
            return XCTFail("expected local quota")
        }
        XCTAssertEqual(used, 42)

        guard let spendLine = combined?.line(label: "Today"),
              case .values(_, let values, _, _, _, _) = spendLine else {
            return XCTFail("expected combined spend")
        }
        XCTAssertEqual(values.first(where: { $0.kind == .count })?.number, 350)
        XCTAssertEqual(values.first(where: { $0.kind == .dollars })?.number, 4.75)

        guard let chartLine = combined?.line(label: "Usage Trend"),
              case .chart(_, let points, let note) = chartLine else {
            return XCTFail("expected combined trend")
        }
        XCTAssertEqual(points.single?.value, 350)
        XCTAssertEqual(note, "Local usage across connected Macs")
    }

    func testRemoteOnlyProviderStillCannotSupplyQuotaOrPlan() {
        let remote = makeSnapshot(quota: 90, tokens: 250, dollars: 3.25, chart: 250)
        let combined = LANUsageAggregator.combinedSnapshots(
            local: [:],
            remotes: ["remote-device": ["test": remote]],
            registry: makeRegistry()
        )["test"]

        XCTAssertNil(combined?.line(label: "Session"))
        XCTAssertNil(combined?.plan)
        XCTAssertNil(combined?.warning)
        XCTAssertNotNil(combined?.line(label: "Today"))
    }

    private func makeRegistry() -> WidgetRegistry {
        WidgetRegistry(
            providers: [provider],
            descriptors: [
                .percent(id: "test.session", provider: provider, title: "Session"),
                WidgetDescriptor.spendTiles(provider: provider)[0],
                .usageTrend(provider: provider)
            ]
        )
    }

    private func makeSnapshot(quota: Double, tokens: Double, dollars: Double, chart: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [
                .progress(label: "Session", used: quota, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: dollars, kind: .dollars, estimated: true),
                    MetricValue(number: tokens, kind: .count, label: "tokens")
                ]),
                .chart(label: "Usage Trend", points: [
                    MetricChartPoint(value: chart, label: "Jul 12", valueLabel: "\(Int(chart)) tokens")
                ], note: "Local")
            ],
            warning: "Local warning"
        )
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
