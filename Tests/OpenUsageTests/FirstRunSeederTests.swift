import XCTest
@testable import OpenUsage

/// Covers the fresh-install seeding flow: only fresh installs are seeded (existing installs keep the
/// legacy all-on default untouched), the fallback set lands synchronously, the detected set replaces it
/// once the local credential probe finishes, and a user's toggle during the probe wins over detection.
@MainActor
final class FirstRunSeederTests: XCTestCase {
    func testFreshInstallSeedsFallbackSynchronouslyThenDetectedSet() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("detect"))
        let onboarding = OnboardingStore(defaults: makeDefaults("detect-onboarding"))
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )

        // Before the probe finishes: the fallback set, synchronously — never a flash of all providers.
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        // Every provider shipping today is baselined as "seen", so `NewProviderSeeder` only ever
        // probes providers added in a later release.
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "cursor", "grok"])

        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testNothingDetectedKeepsFallback() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("none"))
        let onboarding = OnboardingStore(defaults: makeDefaults("none-onboarding"))
        let providers = ["claude", "codex", "cursor", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "cursor"])
    }

    func testExistingInstallIsNeverSeeded() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("existing"))
        let onboarding = OnboardingStore(defaults: makeDefaults("existing-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs, "an existing install keeps legacy all-on semantics")
        XCTAssertTrue(enablement.isEnabled("grok"))
        XCTAssertFalse(onboarding.isCustomizeHintPending, "existing installs never see the hint card")
    }

    func testAlreadySeededStoreIsNotReseeded() {
        // An unbundled `swift run` reports fresh on every launch; the enabled-list guard keeps a
        // second pass from overwriting the user's choices.
        let defaults = makeDefaults("idempotent")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["grok"])
        let onboarding = OnboardingStore(defaults: makeDefaults("idempotent-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("toggle-wins"))
        let onboarding = OnboardingStore(defaults: makeDefaults("toggle-wins-onboarding"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("cursor", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        // The user flips a toggle while the probe is still running: their arrangement must survive.
        enablement.setEnabled(false, for: "codex")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "cursor"])
    }

    // MARK: - OnboardingStore persistence

    func testCustomizeHintFlagPersistsAcrossInstances() {
        let defaults = makeDefaults("hint-persist")
        let store = OnboardingStore(defaults: defaults)
        XCTAssertFalse(store.isCustomizeHintPending)

        store.markCustomizeHintPending()
        XCTAssertTrue(OnboardingStore(defaults: defaults).isCustomizeHintPending)

        store.dismissCustomizeHint()
        XCTAssertFalse(store.isCustomizeHintPending)
        XCTAssertFalse(OnboardingStore(defaults: defaults).isCustomizeHintPending)
    }

    // MARK: - Helpers

    private func stub(_ id: String, hasCredentials: Bool) -> CredentialStubProvider {
        CredentialStubProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.FirstRunSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CredentialStubProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { hasCredentials }
}
