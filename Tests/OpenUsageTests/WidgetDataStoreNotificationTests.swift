import XCTest
@testable import OpenUsage

/// End-to-end coverage of `WidgetDataStore.evaluateNotifications`: it resolves each enabled, visible
/// bounded metric, runs the pure milestone logic, gates on the master + per-trigger settings, dedups
/// per metric per window, and posts one notification per fired milestone. A recording sink stands in
/// for `AppNotifications`; pace worsens by raising the metric's `used` between refreshes (real-world
/// consumption), with `now` pinned so the projection stays deterministic.
@MainActor
final class WidgetDataStoreNotificationTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// Reset window with ~90% of the week already elapsed at `base`, so `used%` ≈ the projected end %.
    private var resetsAt: Date { base.addingTimeInterval(week * 0.10) }

    /// A recording sink for posted notifications: each entry is `(idPrefix, title, body)`.
    private final class Recorder {
        var posts: [(String, String, String)] = []
    }

    /// A mutable enablement flag the store reads through its injected closure (so a test can flip it
    /// without a "mutated after capture" warning on a captured local var).
    private final class EnabledFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// A provider whose snapshot can be swapped between refreshes to simulate rising usage.
    private final class MutableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot
        init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.snapshot = snapshot
        }
        func refresh() async -> ProviderSnapshot { snapshot }
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suite = "WidgetDataStoreNotificationTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))

    private static func descriptor() -> WidgetDescriptor {
        WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 10, limit: 100)
        )
    }

    private func snapshot(used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: Self.provider.id,
            displayName: Self.provider.displayName,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent,
                              resetsAt: resetsAt, periodDurationMs: Int(week * 1000))]
        )
    }

    private func makeStore(
        used: Double,
        settings: NotificationSettingsStore,
        recorder: Recorder,
        defaultsName: String,
        isEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) -> (WidgetDataStore, MutableRuntime, WidgetDescriptor) {
        let descriptor = Self.descriptor()
        let runtime = MutableRuntime(provider: Self.provider, descriptors: [descriptor], snapshot: snapshot(used: used))
        let defaults = makeUserDefaults(defaultsName)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [Self.provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults,
            isProviderEnabled: isEnabled,
            orderedDescriptors: { [descriptor] },
            notificationSettings: { settings },
            postNotification: { idPrefix, title, body in recorder.posts.append((idPrefix, title, body)) }
        )
        return (store, runtime, descriptor)
    }

    func testHealthyToCloseFiresOnceThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("h2c-settings"))
        let recorder = Recorder()
        // 80% used at ~90% elapsed → projected ~89% → healthy.
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "h2c")
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        // Usage rises to 87% → projected ~96.7% → close.
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.first?.0, "test.healthyToClose")
        XCTAssertEqual(recorder.posts.first?.1, "Pace Warning")

        // Staying yellow doesn't re-fire.
        store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
    }

    func testCloseToRunningOutFiresThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("c2r-settings"))
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 87, settings: settings, recorder: recorder, defaultsName: "c2r")
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)   // close → fires healthyToClose (cold→close)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.healthyToClose" })

        // Usage rises to 95% → projected ~105% → red.
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
        XCTAssertTrue(recorder.posts.contains { $0.2 == "Session is projected to run out before it resets." })
    }

    func testMasterOffSuppressesAllPosts() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("master-off-settings"))
        settings.enabled = false
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "master-off")
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testPerTriggerOffSuppressesThatMilestoneOnly() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("per-trigger-settings"))
        settings.healthyToClose = false   // turn off "Pace Warning" only
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "per-trigger")
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertFalse(recorder.posts.contains { $0.0 == "test.healthyToClose" })
        // The critical trigger is still on: pushing to red fires it.
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
    }

    func testDisablingProviderDropsItsNotificationState() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("disable-settings"))
        let recorder = Recorder()
        let enabled = EnabledFlag(true)
        // 95% used → red immediately, so a milestone fires on the first evaluation.
        let (store, _, _) = makeStore(used: 95, settings: settings, recorder: recorder,
                                      defaultsName: "disable", isEnabled: { _ in enabled.value })
        await store.refreshAll(force: true)
        store.evaluateNotifications(now: base)
        let firstCount = recorder.posts.count
        XCTAssertGreaterThan(firstCount, 0)

        // Disable the provider: evaluation skips it (and prunes its state), so nothing new fires.
        enabled.value = false
        store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, firstCount)
    }
}
