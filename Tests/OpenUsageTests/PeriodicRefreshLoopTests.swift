import XCTest
@testable import OpenUsage

/// Guards ordering within the automatic refresh loop. The duplicate dashboard-owned task was removed
/// structurally; these tests verify that the remaining AppContainer-owned loop completes one refresh,
/// notification, and telemetry pipeline before waiting or beginning another.
@MainActor
final class PeriodicRefreshLoopTests: XCTestCase {
    func testCancellationDuringRefreshStopsBeforePostRefreshWork() async {
        let refreshStarted = expectation(description: "refresh started")
        var events: [String] = []

        let task = Task {
            await PeriodicRefreshLoop.run(
                interval: .seconds(300),
                refreshAll: {
                    events.append("refresh")
                    refreshStarted.fulfill()
                    try? await Task.sleep(for: .seconds(60))
                },
                evaluateNotifications: { events.append("notifications") },
                tickTelemetry: { events.append("telemetry") },
                didScheduleNextPass: { events.append("deadline") },
                waitForNextPass: { _ in
                    events.append("wait")
                    return nil
                }
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 1)

        task.cancel()
        await task.value

        XCTAssertEqual(events, ["refresh"])
    }

    func testCancellationDuringNotificationsStopsBeforeTelemetryAndDeadline() async {
        let notificationsStarted = expectation(description: "notifications started")
        var events: [String] = []

        let task = Task {
            await PeriodicRefreshLoop.run(
                interval: .seconds(300),
                refreshAll: { events.append("refresh") },
                evaluateNotifications: {
                    events.append("notifications")
                    notificationsStarted.fulfill()
                    try? await Task.sleep(for: .seconds(60))
                },
                tickTelemetry: { events.append("telemetry") },
                didScheduleNextPass: { events.append("deadline") },
                waitForNextPass: { _ in
                    events.append("wait")
                    return nil
                }
            )
        }
        await fulfillment(of: [notificationsStarted], timeout: 1)

        task.cancel()
        await task.value

        XCTAssertEqual(events, ["refresh", "notifications"])
    }

    func testLaunchRunsOneCompletePassBeforeWaiting() async {
        var events: [String] = []
        let waiting = expectation(description: "first pass reached wait")

        let task = Task {
            await PeriodicRefreshLoop.run(
                interval: .seconds(300),
                refreshAll: { events.append("refresh") },
                evaluateNotifications: { events.append("notifications") },
                tickTelemetry: { events.append("telemetry") },
                didScheduleNextPass: {},
                waitForNextPass: { _ in
                    events.append("wait")
                    waiting.fulfill()
                    try? await Task.sleep(for: .seconds(60))
                    return nil
                }
            )
        }
        await fulfillment(of: [waiting], timeout: 1)

        XCTAssertEqual(events, ["refresh", "notifications", "telemetry", "wait"])

        task.cancel()
        await task.value
    }

    func testOneWakeRunsExactlyOneMoreCompletePass() async {
        let wakeName = Notification.Name("PeriodicRefreshLoopTests.wake")
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)
        var events: [String] = []
        let firstWait = expectation(description: "launch pass reached wait")
        let secondWait = expectation(description: "wake pass reached wait")
        var waitCount = 0

        let task = Task {
            await PeriodicRefreshLoop.run(
                interval: .seconds(300),
                refreshAll: { events.append("refresh") },
                evaluateNotifications: { events.append("notifications") },
                tickTelemetry: { events.append("telemetry") },
                didScheduleNextPass: {},
                waitForNextPass: { timeout in
                    waitCount += 1
                    events.append("wait")
                    if waitCount == 1 {
                        firstWait.fulfill()
                    } else if waitCount == 2 {
                        secondWait.fulfill()
                    }
                    return await signal.wait(timeout: timeout)
                }
            )
        }
        await fulfillment(of: [firstWait], timeout: 1)
        center.post(name: wakeName, object: nil)
        await fulfillment(of: [secondWait], timeout: 1)

        XCTAssertEqual(
            events,
            [
                "refresh", "notifications", "telemetry", "wait",
                "refresh", "notifications", "telemetry", "wait",
            ]
        )

        task.cancel()
        await task.value
    }

    func testEarlyWakeKeepsTimeRemainingOnScheduledCadence() async {
        var now = ContinuousClock.now
        let wallStart = Date(timeIntervalSince1970: 1_800_000_000)
        var wallNow = wallStart
        var nextAutomaticRefreshAt: Date?
        var passCount = 0
        var timeouts: [Duration] = []

        await PeriodicRefreshLoop.run(
            interval: .seconds(300),
            clockNow: { now },
            refreshAll: { passCount += 1 },
            evaluateNotifications: {},
            tickTelemetry: {},
            didScheduleNextPass: {
                nextAutomaticRefreshAt = wallNow.addingTimeInterval(300)
            },
            waitForNextPass: { timeout in
                timeouts.append(timeout)
                if timeouts.count == 1 {
                    // Enable a provider four minutes into the five-minute cadence. The wake pass must
                    // leave one minute on the timer, not restart a fresh five-minute sleep.
                    now = now.advanced(by: .seconds(240))
                    wallNow = wallNow.addingTimeInterval(240)
                    return .enablementChange
                }
                return nil
            }
        )

        XCTAssertEqual(passCount, 2)
        XCTAssertEqual(timeouts, [.seconds(300), .seconds(60)])
        XCTAssertEqual(nextAutomaticRefreshAt, wallStart.addingTimeInterval(300))
        XCTAssertEqual(
            PopoverFooter.countdownText(nextAutomaticRefreshAt: nextAutomaticRefreshAt, now: wallNow),
            "Next update in 1m"
        )
    }

    func testWakePassCrossingDeadlineRunsScheduledPassImmediately() async {
        var now = ContinuousClock.now
        var passCount = 0
        var timeouts: [Duration] = []

        await PeriodicRefreshLoop.run(
            interval: .seconds(300),
            clockNow: { now },
            refreshAll: {
                passCount += 1
                if passCount == 2 {
                    // The early pass starts just before expiry but finishes just after it. Providers
                    // that were cache hits at the start still need the now-due scheduled pass.
                    now = now.advanced(by: .seconds(2))
                }
            },
            evaluateNotifications: {},
            tickTelemetry: {},
            didScheduleNextPass: {},
            waitForNextPass: { timeout in
                timeouts.append(timeout)
                switch timeouts.count {
                case 1:
                    now = now.advanced(by: .seconds(299))
                    return .enablementChange
                case 2:
                    return .timer
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(passCount, 3)
        XCTAssertEqual(timeouts, [.seconds(300), .zero, .seconds(300)])
    }

    func testManualRefreshDoesNotMoveAutomaticDeadline() async {
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: []
        )
        let deadline = Date(timeIntervalSince1970: 1_800_000_300)
        store.nextAutomaticRefreshAt = deadline

        await store.refreshAll(force: true)

        XCTAssertEqual(store.nextAutomaticRefreshAt, deadline)
    }
}
