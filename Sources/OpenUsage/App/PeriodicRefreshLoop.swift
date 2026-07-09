import Foundation

/// The app's single automatic refresh pipeline. `AppContainer` owns its task for the whole process
/// lifetime; views only observe the resulting store changes and never start an automatic pass.
///
/// Keeping the sequencing here makes the lifecycle explicit and testable: every launch/wake pass
/// finishes refreshing before quota notifications and telemetry inspect the new state, then waits for
/// the next timer or provider-enablement wake. An early enablement pass preserves the scheduled timer
/// deadline, so cache hits cannot postpone the next live refresh by another full interval.
@MainActor
enum PeriodicRefreshLoop {
    static func run(
        interval: Duration,
        clockNow: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        refreshAll: @MainActor () async -> Void,
        evaluateNotifications: @MainActor () async -> Void,
        tickTelemetry: @MainActor () -> Void,
        didScheduleNextPass: @MainActor () -> Void,
        waitForNextPass: @MainActor (Duration) async -> RefreshWakeSignal.Trigger?
    ) async {
        var deadline: ContinuousClock.Instant?
        var trigger: RefreshWakeSignal.Trigger?

        while !Task.isCancelled {
            await refreshAll()
            // Cancellation can land while providers are in flight. Once that pass unwinds, stop before
            // treating it as a completed cycle through notifications, telemetry, or a new deadline.
            guard !Task.isCancelled else { return }
            await evaluateNotifications()
            // Notification delivery also suspends. A cancellation there must not leak into telemetry or
            // publish a deadline for a cycle that will never wait for that deadline.
            guard !Task.isCancelled else { return }
            tickTelemetry()

            // Launch and scheduled-timer passes begin a new cadence interval. An early enablement pass
            // deliberately leaves the deadline alone: otherwise a wake just before expiry could turn
            // the five-minute cadence into almost ten minutes between live provider fetches.
            if deadline == nil || trigger == .timer {
                deadline = clockNow().advanced(by: interval)
                didScheduleNextPass()
            }
            guard let deadline else { return }
            let remaining = max(.zero, clockNow().duration(to: deadline))
            guard let nextTrigger = await waitForNextPass(remaining) else { return }
            trigger = nextTrigger
        }
    }
}
