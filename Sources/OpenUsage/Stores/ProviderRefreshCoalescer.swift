import Foundation
import os

extension WidgetDataStore {
    /// What a single provider request actually did, so `refreshAll` can summarize the batch from real
    /// outcomes rather than cumulative error state. Ordinary joiners receive the active request's
    /// outcome; forced joiners receive the follow-up that consumes their intent.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }
}

/// Pending work behind `WidgetDataStore`'s per-provider in-flight guard. An ordinary caller receives
/// the active request's outcome; a forced caller queues a post-flight probe and receives the outcome
/// of the probe that consumes its intent. Keeping this bookkeeping separate leaves the store focused
/// on fetch policy and snapshot updates.
@MainActor
final class ProviderRefreshCoalescer {
    /// `Task.cancel()` invokes its handler off-actor. This flag closes the interval before the cleanup
    /// hop reaches MainActor, so an owner cannot claim a force from an already-cancelled waiter.
    private final class WaiterCancellation: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        var isCancelled: Bool {
            cancelled.withLock { $0 }
        }
    }

    private struct Waiter {
        let id: UUID
        let waitsForForcedRefresh: Bool
        var needsForcedRefresh: Bool
        let cancellation: WaiterCancellation
        let continuation: CheckedContinuation<WidgetDataStore.RefreshOutcome, Never>
    }

    /// Provenance for one claimed follow-up. Enablement intent exists independently of a caller;
    /// waiter intent stays live only while at least one of the recorded callers remains uncancelled.
    /// Keeping that distinction lets a cancelled owner restore only work somebody still wants.
    struct ForcedRefreshClaim {
        fileprivate let includesEnablementIntent: Bool
        fileprivate let waiterIDs: Set<UUID>
    }

    /// Forced work requested without a waiting caller, currently provider re-enablement during an
    /// active request. Waiting force callers carry their own pending flag in `waiters` so cancelling the
    /// last such caller also withdraws work that nobody is waiting for.
    private var queuedForcedProviderIDs: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func join(
        providerID: String,
        force: Bool,
        onRegistered: @MainActor () -> Void = {}
    ) async -> WidgetDataStore.RefreshOutcome {
        let waiterID = UUID()
        let cancellation = WaiterCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .skipped }
            return await withCheckedContinuation { continuation in
                register(
                    providerID: providerID,
                    waiterID: waiterID,
                    force: force,
                    cancellation: cancellation,
                    continuation: continuation,
                    onRegistered: onRegistered
                )
            }
        } onCancel: {
            // Mark synchronously before the actor hop. `has/takeQueuedForcedRefresh` consult this flag,
            // so the owner cannot race ahead and claim work from the cancelled waiter.
            cancellation.cancel()
            // Cancellation handlers are nonisolated. Hop back to this actor to remove and release only
            // the cancelled waiter; the active provider request belongs to another caller.
            Task.detached { [weak self] in
                await self?.cancelWaiter(providerID: providerID, waiterID: waiterID)
            }
        }
    }

    private func register(
        providerID: String,
        waiterID: UUID,
        force: Bool,
        cancellation: WaiterCancellation,
        continuation: CheckedContinuation<WidgetDataStore.RefreshOutcome, Never>,
        onRegistered: @MainActor () -> Void
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(returning: .skipped)
            return
        }
        waiters[providerID, default: []].append(Waiter(
            id: waiterID,
            waitsForForcedRefresh: force,
            needsForcedRefresh: force,
            cancellation: cancellation,
            continuation: continuation
        ))
        onRegistered()
    }

    /// Remove and return one cancelled waiter so the store can resume it promptly as `.skipped`.
    /// Its force request disappears with it unless another waiter or an explicit queue still needs one.
    private func removeWaiter(
        providerID: String,
        waiterID: UUID
    ) -> CheckedContinuation<WidgetDataStore.RefreshOutcome, Never>? {
        guard var providerWaiters = waiters[providerID],
              let index = providerWaiters.firstIndex(where: { $0.id == waiterID })
        else { return nil }

        let continuation = providerWaiters.remove(at: index).continuation
        if providerWaiters.isEmpty {
            waiters[providerID] = nil
        } else {
            waiters[providerID] = providerWaiters
        }
        return continuation
    }

    private func cancelWaiter(providerID: String, waiterID: UUID) {
        removeWaiter(providerID: providerID, waiterID: waiterID)?
            .resume(returning: .skipped)
    }

    func queueEnablementForcedRefresh(providerID: String) {
        queuedForcedProviderIDs.insert(providerID)
    }

    func hasQueuedForcedRefresh(providerID: String) -> Bool {
        queuedForcedProviderIDs.contains(providerID)
            || waiters[providerID]?.contains(where: {
                $0.needsForcedRefresh && !$0.cancellation.isCancelled
            }) == true
    }

    func takeQueuedForcedRefresh(providerID: String) -> ForcedRefreshClaim? {
        let includesEnablementIntent = queuedForcedProviderIDs.remove(providerID) != nil
        var claimedWaiterIDs: Set<UUID> = []
        guard var providerWaiters = waiters[providerID] else {
            return includesEnablementIntent
                ? ForcedRefreshClaim(includesEnablementIntent: true, waiterIDs: [])
                : nil
        }

        for index in providerWaiters.indices
        where providerWaiters[index].needsForcedRefresh && !providerWaiters[index].cancellation.isCancelled {
            providerWaiters[index].needsForcedRefresh = false
            claimedWaiterIDs.insert(providerWaiters[index].id)
        }
        waiters[providerID] = providerWaiters
        guard includesEnablementIntent || !claimedWaiterIDs.isEmpty else { return nil }
        return ForcedRefreshClaim(
            includesEnablementIntent: includesEnablementIntent,
            waiterIDs: claimedWaiterIDs
        )
    }

    /// Restore a follow-up interrupted with its owner, retaining its original provenance. A cancelled
    /// waiter is deliberately absent from the restored queue, while enablement intent survives without
    /// a waiter because it represents a user action whose wake still needs a fresh request.
    func restoreQueuedForcedRefresh(
        _ claim: ForcedRefreshClaim,
        providerID: String
    ) -> Bool {
        if claim.includesEnablementIntent {
            queuedForcedProviderIDs.insert(providerID)
        }
        if var providerWaiters = waiters[providerID] {
            for index in providerWaiters.indices
            where claim.waiterIDs.contains(providerWaiters[index].id)
                && !providerWaiters[index].cancellation.isCancelled {
                providerWaiters[index].needsForcedRefresh = true
            }
            waiters[providerID] = providerWaiters
        }
        return hasQueuedForcedRefresh(providerID: providerID)
    }

    func hasLiveIntent(_ claim: ForcedRefreshClaim, providerID: String) -> Bool {
        claim.includesEnablementIntent
            || waiters[providerID]?.contains(where: {
                claim.waiterIDs.contains($0.id) && !$0.cancellation.isCancelled
            }) == true
    }

    /// Complete callers that joined only the request that just finished. Forced callers stay queued
    /// for the specific forced claim that consumes their intent.
    func resolveNonForcedWaiters(
        providerID: String,
        outcome: WidgetDataStore.RefreshOutcome
    ) {
        guard let providerWaiters = waiters[providerID] else { return }
        let completed = providerWaiters.filter { !$0.waitsForForcedRefresh }
        let remaining = providerWaiters.filter(\.waitsForForcedRefresh)
        waiters[providerID] = remaining.isEmpty ? nil : remaining
        for waiter in completed {
            waiter.continuation.resume(returning: waiter.cancellation.isCancelled ? .skipped : outcome)
        }
    }

    /// Complete only the forced callers whose intent this claim consumed. Later forced callers belong
    /// to a newer claim, so their cancellation or disablement can never rewrite this cohort's result.
    func resolveClaimedWaiters(
        _ claim: ForcedRefreshClaim,
        providerID: String,
        outcome: WidgetDataStore.RefreshOutcome
    ) {
        guard let providerWaiters = waiters[providerID] else { return }
        let completed = providerWaiters.filter { claim.waiterIDs.contains($0.id) }
        let remaining = providerWaiters.filter { !claim.waiterIDs.contains($0.id) }
        waiters[providerID] = remaining.isEmpty ? nil : remaining
        for waiter in completed {
            waiter.continuation.resume(returning: waiter.cancellation.isCancelled ? .skipped : outcome)
        }
    }

}
