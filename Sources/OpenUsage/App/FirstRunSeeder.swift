import Foundation

/// Seeds a fresh install's enabled providers so the first launch shows only the tools the user
/// actually has, instead of every provider OpenUsage knows about.
///
/// Two steps, both on the first launch only (existing installs keep their all-on legacy default and
/// are never touched):
/// 1. **Synchronously** switch `ProviderEnablementStore` into enabled-list mode with the established
///    fallback set (Claude, Codex, Cursor), so the dashboard and menu bar never flash all providers.
/// 2. **Asynchronously** probe every provider's `hasLocalCredentials()` (local files/keychain only, no
///    network) and replace the fallback with exactly the detected set — unless nothing was detected
///    (keep the fallback) or the user already touched the toggles while the probe ran (their choice wins).
@MainActor
enum FirstRunSeeder {
    /// The established providers (see AGENTS.md "## Providers"), shown when detection finds nothing.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex", "cursor"]

    /// Returns the detection task (for tests to await), or `nil` when no seeding happened. The
    /// `enabledIDs == nil` guard makes seeding idempotent: an already-seeded store (e.g. an unbundled
    /// `swift run`, which always reports fresh) is never overwritten.
    @discardableResult
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore
    ) -> Task<Void, Never>? {
        guard isFreshInstall, enablement.enabledIDs == nil else { return nil }

        let known = Set(providers.map(\.provider.id))
        let fallback = fallbackProviderIDs.intersection(known)
        enablement.seedEnabledProviders(fallback)
        // Baseline the known-provider set: everything shipping today has been "seen" by this install,
        // so `NewProviderSeeder` only ever probes providers added in a later release.
        enablement.registerKnownProviders(known)
        onboarding.markCustomizeHintPending()
        AppLog.info(.config, "first run: seeded providers \(fallback.sorted()); probing local credentials")

        return Task {
            var detected = Set<String>()
            for provider in providers where await provider.hasLocalCredentials() {
                detected.insert(provider.provider.id)
            }
            AppLog.info(.config, "first run: detected credentials for \(detected.sorted())")
            // The probe takes a moment; a toggle the user flipped meanwhile wins over detection.
            guard enablement.enabledIDs == fallback, !detected.isEmpty else { return }
            enablement.seedEnabledProviders(detected)
        }
    }
}
