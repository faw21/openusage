import XCTest
@testable import OpenUsage

/// Covers the refresh cadence as the single source of truth: `RefreshSetting`'s fixed interval, and the
/// snapshot cache treating a snapshot as fresh for exactly one interval (so cached data survives a
/// relaunch within the interval and is refetched once past it).
@MainActor
final class RefreshSettingTests: XCTestCase {
    // MARK: - Fixed cadence

    func testCadenceIsFixedAtFiveMinutes() {
        XCTAssertEqual(RefreshSetting.defaultMinutes, 5)
        XCTAssertEqual(RefreshSetting.interval, 300)
    }

    // MARK: - Cache TTL tied to the interval

    func testCacheReusedAcrossRestartWithinInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-within")

        // A prior session left a snapshot 4 minutes ago — inside the 5-minute interval.
        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0) // within interval => served from cache, no fetch
        XCTAssertNotNil(store.snapshots["test"])
    }

    func testCacheExpiresPastInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-expired")

        // A prior session left a snapshot 6 minutes ago — older than the 5-minute interval.
        storeSnapshot(used: 20, age: 360, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1) // past interval => refetched
    }

    // MARK: - Helpers

    private func storeSnapshot(used: Double, age: TimeInterval, into suite: UserDefaults, now: Date) {
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        ))
    }

    private func makeRuntime(used: Double) -> CountingProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: "test",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: used, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "test",
                displayName: "Test",
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// Builds a store backed by a cache at the default (fixed) refresh-interval TTL — the relaunch case.
    private func makeStore(runtime: CountingProviderRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now }),
            defaults: suite
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.RefreshSetting.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
