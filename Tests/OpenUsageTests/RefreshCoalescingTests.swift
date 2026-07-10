import XCTest
@testable import OpenUsage

/// Covers the per-provider refresh gate. Only one provider request may run at a time, but an explicit
/// force that arrives after the active request loaded its credentials must survive as one fresh follow-up.
@MainActor
final class RefreshCoalescingTests: XCTestCase {

    // MARK: - Fixtures

    struct Fixture {
        let store: WidgetDataStore
        let runtime: SuspendedSequenceProviderRuntime
    }

    var testProvider: Provider {
        Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
    }

    func makeFixture(
        snapshots: [ProviderSnapshot],
        isEnabled: @escaping @MainActor () -> Bool = { true }
    ) -> Fixture {
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: testProvider.id,
            metricLabel: "Session",
            sample: WidgetData(
                title: "Session",
                icon: testProvider.icon,
                kind: .percent,
                used: 0,
                limit: 100
            )
        )
        let runtime = SuspendedSequenceProviderRuntime(
            provider: testProvider,
            descriptors: [descriptor],
            snapshots: snapshots
        )
        let defaults = UserDefaults(suiteName: "RefreshCoalescingTests.\(UUID().uuidString)")!
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [testProvider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            isProviderEnabled: { _ in isEnabled() }
        )
        return Fixture(store: store, runtime: runtime)
    }

    func successSnapshot(used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: testProvider.id,
            displayName: testProvider.displayName,
            lines: [sessionLine(used: used)]
        )
    }

    func sessionLine(used: Double) -> MetricLine {
        .progress(label: "Session", used: used, limit: 100, format: .percent)
    }
}
