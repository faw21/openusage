import Foundation
import UserNotifications

/// The single entry point for posting macOS user notifications. Quota pace alerts go through `post`;
/// authorization is requested once at launch (the master toggle defaults ON, so the prompt is expected).
///
/// Authorization is memoized in one `Task<Bool, Never>`: the first caller reads the current settings,
/// short-circuits an already-authorized or already-denied state, and otherwise requests it; every later
/// caller awaits the same task rather than re-prompting. The class is the notification-center delegate so
/// banners still show while the app is frontmost (a menu-bar accessory usually is).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    /// Injectable so tests can supply a fake center and assert what got scheduled. Production returns
    /// the system `current()` center.
    private let centerProvider: @Sendable () -> UNUserNotificationCenter

    /// Memoized authorization request — created on first use, awaited by everyone after.
    private var authorizationTask: Task<Bool, Never>?

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
        super.init()
    }

    /// True while running inside the XCTest harness, so a unit test never actually schedules a system
    /// notification or trips the authorization prompt. (No XCTest symbol is linked into the app target,
    /// so this is a runtime class lookup.)
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Make this object the delegate and kick off the authorization request once at launch. Safe to call
    /// from app launch; a no-op under tests.
    func registerAsDelegate() {
        guard !Self.isRunningUnderTests else { return }
        centerProvider().delegate = self
    }

    /// Request notification authorization once at startup. Because the master toggle defaults ON, the
    /// permission prompt is expected on first launch. Memoized, so repeated calls don't re-prompt.
    @discardableResult
    func requestAuthorizationOnStartup() -> Task<Bool, Never> {
        ensureAuthorization()
    }

    /// Post one immediate notification. `idPrefix` names the source (e.g. a metric key) for the log line;
    /// the actual identifier is made unique so repeated alerts on the same metric don't coalesce. No-op
    /// under tests, when authorization is denied, or when notifications can't be authorized.
    func post(idPrefix: String, title: String, body: String, soundEnabled: Bool = true) {
        guard !Self.isRunningUnderTests else { return }
        Task {
            let authorized = await ensureAuthorization().value
            guard authorized else {
                AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if soundEnabled { content.sound = .default }
            let id = "openusage-\(idPrefix)-\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try await centerProvider().add(request)
                AppLog.info(.notifications, "posted \(idPrefix)")
            } catch {
                AppLog.error(.notifications, "post \(idPrefix) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Authorization

    /// The shared authorization task, created on first call. Reads current settings, short-circuits a
    /// resolved (authorized/denied) state, and otherwise requests alert + sound permission.
    private func ensureAuthorization() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let center = centerProvider()
        let task = Task<Bool, Never> {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                AppLog.info(.notifications, "authorization denied")
                return false
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    AppLog.info(.notifications, "authorization \(granted ? "granted" : "refused")")
                    return granted
                } catch {
                    AppLog.error(.notifications, "authorization request failed: \(error.localizedDescription)")
                    return false
                }
            @unknown default:
                return false
            }
        }
        authorizationTask = task
        return task
    }

    /// Current authorization status, for the Settings screen's denied-permission notice. Returns
    /// `.notDetermined` under tests.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard !Self.isRunningUnderTests else { return .notDetermined }
        return await centerProvider().notificationSettings().authorizationStatus
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner (and play sound) even when the app is frontmost — a menu-bar accessory is
    /// effectively always frontmost, so without this the user would never see the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
