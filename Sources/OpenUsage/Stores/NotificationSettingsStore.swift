import Foundation
import Observation

/// User preferences for quota pace notifications: a master switch and the three per-milestone
/// triggers. All default ON (owner decision) — a fresh install starts alerting, and the app requests
/// notification authorization on first launch because of that.
///
/// Persisted in `UserDefaults` (each key independently, so an unset key reads its `true` default and a
/// future-added trigger defaults on without migration). `@Observable` so the Settings toggles and the
/// evaluation in `WidgetDataStore` read live values.
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults

    private static let masterKey = "openusage.notifications.enabled"
    private static let underTenKey = "openusage.notifications.underTenPercent"
    private static let healthyToCloseKey = "openusage.notifications.healthyToClose"
    private static let closeToRunningOutKey = "openusage.notifications.closeToRunningOut"

    /// Master switch. When off, no quota notification fires regardless of the per-trigger toggles.
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.masterKey) }
    }

    /// Alert the first time a metric drops under 10% remaining for the period.
    var underTenPercent: Bool {
        didSet { defaults.set(underTenPercent, forKey: Self.underTenKey) }
    }

    /// Alert when pace worsens from healthy (blue) to close-to-limit (yellow).
    var healthyToClose: Bool {
        didSet { defaults.set(healthyToClose, forKey: Self.healthyToCloseKey) }
    }

    /// Alert when pace worsens from close-to-limit (yellow) to running-out (red).
    var closeToRunningOut: Bool {
        didSet { defaults.set(closeToRunningOut, forKey: Self.closeToRunningOutKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.boolWithDefault(Self.masterKey, default: true)
        self.underTenPercent = defaults.boolWithDefault(Self.underTenKey, default: true)
        self.healthyToClose = defaults.boolWithDefault(Self.healthyToCloseKey, default: true)
        self.closeToRunningOut = defaults.boolWithDefault(Self.closeToRunningOutKey, default: true)
    }

    /// The per-milestone toggles as the pure logic consumes them. The master switch is applied
    /// separately by the caller (it gates the whole evaluation, not one milestone).
    var toggles: PaceNotificationToggles {
        PaceNotificationToggles(
            underTenPercent: underTenPercent,
            healthyToClose: healthyToClose,
            closeToRunningOut: closeToRunningOut
        )
    }
}

private extension UserDefaults {
    /// `bool(forKey:)` returns `false` for an unset key, which can't express an opt-out default. This
    /// reads the stored bool when present and falls back to `default` only when the key is genuinely
    /// unset — so a default-on toggle starts on yet still honors a user's explicit off.
    func boolWithDefault(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }
}
