import Foundation

/// The refresh loop's between-passes wait: sleeps one refresh interval, but wakes early when the
/// enabled-provider set changes — and, crucially, never loses a change that lands *during* a pass.
///
/// The bug this replaces: the loop used to subscribe to
/// `ProviderEnablementStore.didChangeNotification` only inside its wait, after `refreshAll()` had
/// finished. First-run credential detection is local-only and fast while the first refresh pass does
/// network I/O and is slow, so the "providers enabled" notification almost always fired mid-pass with
/// nobody listening — `NotificationCenter.notifications(named:)` doesn't buffer events from before
/// iteration starts. The wake was silently dropped and the newly detected providers sat dataless until
/// the next scheduled pass or a manual refresh. The same lost wake hit `NewProviderSeeder` and the
/// Customize "Reset All" reseed.
///
/// Here the subscription is installed once, synchronously, in `init` — before the loop's first pass —
/// feeding an `AsyncStream` with `.bufferingNewest(1)`: a wake posted while nobody is waiting is
/// retained, and a burst coalesces into a single pending wake, so the next `wait` returns immediately
/// instead of sleeping out the interval.
@MainActor
final class RefreshWakeSignal {
    enum Trigger: Equatable, Sendable {
        case enablementChange
        case timer
    }

    private let stream: AsyncStream<Trigger>
    private let continuation: AsyncStream<Trigger>.Continuation
    private let center: NotificationCenter
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can unregister the observer; it is immutable
    /// after `init`, and `NotificationCenter` is documented thread-safe.
    private nonisolated(unsafe) let observer: NSObjectProtocol

    init(
        name: Notification.Name = ProviderEnablementStore.didChangeNotification,
        center: NotificationCenter = .default
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Trigger.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
        self.center = center
        // Registered synchronously, so no notification posted after `init` returns can be missed.
        // The continuation is `Sendable`; yielding from whatever context posts is safe.
        self.observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            continuation.yield(.enablementChange)
        }
    }

    deinit {
        center.removeObserver(observer)
        continuation.finish()
    }

    /// Returns what ended the wait: a provider-enablement change (including one buffered while the
    /// caller was doing other work), or the scheduled timer. Returns `nil` when the surrounding task is
    /// cancelled. Keeping the two triggers distinct lets the refresh loop preserve its existing timer
    /// deadline across an early enablement pass instead of starting a fresh full interval.
    ///
    /// If the timer and a wake race, the loser stays buffered. The resulting extra pass is harmless
    /// because provider cache checks still gate network work.
    ///
    /// The refresh loop is the signal's only consumer, and only ever sequentially: each call makes a
    /// fresh iterator over the shared stream (fine sequentially — the buffer lives on the stream), so
    /// no actor-isolated iterator state has to survive a suspension.
    func wait(timeout: Duration) async -> Trigger? {
        let timer = Task { [continuation] in
            do {
                try await Task.sleep(for: max(.zero, timeout))
            } catch {
                return
            }
            continuation.yield(.timer)
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
