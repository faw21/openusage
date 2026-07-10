import XCTest
@testable import OpenUsage

extension RefreshCoalescingTests {
    func testCancellingJoinedCallerReturnsPromptlyWithoutCancellingOwner() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
        let joinedFinished = expectation(description: "cancelled joined caller returned")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let joinedReturned = MutableFlag(value: false)
        let joinedEntered = expectation(description: "ordinary caller entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if !force { joinedEntered.fulfill() }
        }
        let joined = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id)
            joinedReturned.value = true
            joinedFinished.fulfill()
            return outcome
        }
        await fulfillment(of: [joinedEntered], timeout: 1)
        XCTAssertFalse(joinedReturned.value, "the caller must be registered behind the active owner")

        joined.cancel()
        await fulfillment(of: [joinedFinished], timeout: 1)

        let joinedOutcome = await joined.value
        XCTAssertTrue(joinedOutcome == .skipped)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.contains(testProvider.id))
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
    }

    func testCancellingOnlyForcedWaiterWithdrawsItsFollowUp() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
        let forcedFinished = expectation(description: "cancelled force returned")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let forcedEntered = expectation(description: "force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedEntered.fulfill() }
        }
        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedFinished.fulfill()
            return outcome
        }
        await fulfillment(of: [forcedEntered], timeout: 1)

        forced.cancel()
        // Resume the owner immediately, before the cancellation cleanup task can hop back to MainActor.
        // The synchronous cancellation flag must still prevent this owner from claiming the force.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        await fulfillment(of: [forcedFinished], timeout: 1)
        let forcedOutcome = await forced.value

        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1, "a cancelled sole force must not leave orphaned work")
    }

    func testCancellingClaimedForceAndOwnerDoesNotRestoreOwnerlessWork() async {
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 40), successSnapshot(used: 80)]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
        let forcedFinished = expectation(description: "cancelled force returned")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forcedEntered = expectation(description: "force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedEntered.fulfill() }
        }
        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedFinished.fulfill()
            return outcome
        }
        await fulfillment(of: [forcedEntered], timeout: 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        // The follow-up already claimed this waiter's force. Cancelling the waiter must still revoke
        // that provenance; cancelling the owner afterward cannot restore it as independent work.
        forced.cancel()
        await fulfillment(of: [forcedFinished], timeout: 1)
        original.cancel()
        fixture.runtime.resumeNext()

        let forcedOutcome = await forced.value
        let originalOutcome = await original.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "no live requester remains for a third fetch")
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testCancellingOwnerAfterClaimedForceSucceedsDoesNotReplayCompletedClaim() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 80),
                successSnapshot(used: 95),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
            if count == 3 {
                // Keep a regressed implementation from hanging the test on its erroneous replay.
                Task {
                    await Task.yield()
                    fixture.runtime.resumeNext()
                }
            }
        }

        var original: Task<WidgetDataStore.RefreshOutcome, Never>?
        fixture.store.onRefreshOutcome = { _, outcome, _, force in
            // Cancellation lands after the forced request committed its successful snapshot but before
            // the owner resumes from performRefresh. The consumed claim is already satisfied.
            if force, outcome == .refreshed, fixture.runtime.refreshCount == 2 {
                original?.cancel()
            }
        }

        original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forcedEntered = expectation(description: "force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedEntered.fulfill() }
        }
        let forced = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [forcedEntered], timeout: 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)
        fixture.runtime.resumeNext()

        let originalOutcome = await original?.value
        let forcedOutcome = await forced.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertTrue(forcedOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "completed forced work must not be replayed")
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }
}
