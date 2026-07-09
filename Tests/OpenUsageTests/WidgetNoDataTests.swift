import XCTest
@testable import OpenUsage

/// Covers the "No data" state: a placed tile whose provider snapshot has no line matching the
/// descriptor's metric label must report `hasData == false`, render the exact "—"/"No data" copy,
/// and never leak its placeholder sample numbers into the menu bar.
@MainActor
final class WidgetNoDataTests: XCTestCase {
    func testDataForFlagsMissingLineAsNoData() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "missing-line")

        XCTAssertTrue(store.data(for: present).hasData)
        XCTAssertFalse(store.data(for: missing).hasData)
    }

    func testNoDataHeadlineAndSubtitleCopy() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "copy")

        let blank = store.data(for: missing)
        XCTAssertFalse(blank.hasData)
        XCTAssertEqual(blank.headline, "—")
        XCTAssertEqual(blank.subtitle, "No data")

        let real = store.data(for: present)
        XCTAssertTrue(real.hasData)
        XCTAssertNotEqual(real.headline, "—")
        XCTAssertNotEqual(real.subtitle, "No data")
    }

    func testValueTextHidesPlaceholderWhenNoData() async {
        // The Add-Widget gallery prints `valueText`; a missing line must never leak the descriptor's
        // placeholder sample numbers there, so `valueText` reports the no-data marker just like the tile.
        let (store, present, missing) = await makeRefreshedStore(suite: "valuetext")

        XCTAssertEqual(store.data(for: missing).valueText, WidgetData.noDataHeadline)
        XCTAssertNotEqual(store.data(for: present).valueText, WidgetData.noDataHeadline)
    }

    func testMalformedTextMetricsNeverBecomeSampleData() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.MalformedText.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: tempDir, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: tempDir)
        }

        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))
        let descriptors = [
            textDescriptor(provider, id: "test.dollars", label: "Dollars", kind: .dollars),
            textDescriptor(provider, id: "test.count", label: "Count", kind: .count),
            textDescriptor(provider, id: "test.percent", label: "Percent", kind: .percent)
        ]
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .text(label: "Dollars", value: "unavailable"),
                    .text(label: "Count", value: "unknown"),
                    .text(label: "Percent", value: "not a number")
                ]
            )
        )
        let defaults = makeUserDefaults("malformed-text")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: makeCache(defaults),
            defaults: defaults
        )

        await store.refreshAll()

        // Render reads are intentionally repeated: the warning belongs to snapshot ingestion and must
        // not be re-emitted every time SwiftUI or the menu-bar asks for the same resolved value.
        for _ in 0..<3 {
            for descriptor in descriptors {
                let data = store.data(for: descriptor)
                XCTAssertFalse(data.hasData, descriptor.id)
                XCTAssertEqual(data.headline, WidgetData.noDataHeadline, descriptor.id)
                XCTAssertEqual(data.unboundedDetail, WidgetData.noDataSubtitle, descriptor.id)
                XCTAssertNotEqual(data.valueText, descriptor.sample.valueText, descriptor.id)
            }
        }

        let log = (try? String(contentsOf: sink.fileURL, encoding: .utf8)) ?? ""
        for descriptor in descriptors {
            let marker = "text metric '\(descriptor.id)'"
            XCTAssertEqual(log.components(separatedBy: marker).count - 1, 1, log)
        }
    }

    // Menu-bar ordering / no-data-skip / fallback are exercised on the real tray path
    // (MenuBarContentBuilder + LayoutStore.pinnedGroups) in MenuBarContentTests and MenuBarPinTests.

    // MARK: - Helpers

    private func makeRefreshedStore(
        suite: String
    ) async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))
        let present = boundedPercent(provider, id: "test.present", metric: "Present", sampleUsed: 40)
        // Deliberately fake sample numbers we must never show once the account lacks this metric.
        let missing = boundedPercent(provider, id: "test.missing", metric: "Missing", sampleUsed: 99)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [present, missing],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Present", used: 40, limit: 100, format: .percent)]
            )
        )
        let defaults = makeUserDefaults(suite)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [present, missing]),
            providers: [runtime],
            cache: makeCache(defaults),
            defaults: defaults
        )
        await store.refreshAll()
        return (store, present, missing)
    }

    private func boundedPercent(
        _ provider: Provider,
        id: String,
        metric: String,
        sampleUsed: Double
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metric,
            sample: WidgetData(
                title: metric,
                icon: provider.icon,
                kind: .percent,
                used: sampleUsed,
                limit: 100
            )
        )
    }

    private func textDescriptor(
        _ provider: Provider,
        id: String,
        label: String,
        kind: MetricKind
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: label,
            sample: WidgetData(title: label, icon: provider.icon, kind: kind, used: 73, limit: nil)
        )
    }

    private func makeCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NoData.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
