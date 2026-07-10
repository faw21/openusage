import XCTest
@testable import OpenUsage

extension RefreshCoalescingTests {
    func testCancelledOwnerHandsQueuedForceToFreshTask() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "Cancelled owner result."),
                successSnapshot(used: 80),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "handed-off forced refresh started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }
        var telemetry: [(outcome: WidgetDataStore.RefreshOutcome, manual: Bool)] = []
        fixture.store.onRefreshOutcome = { _, outcome, _, manual in
            telemetry.append((outcome, manual))
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let forcedReturned = MutableFlag(value: false)
        let forcedEntered = expectation(description: "force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedEntered.fulfill() }
        }
        let forced = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            forcedReturned.value = true
            return outcome
        }
        await fulfillment(of: [forcedEntered], timeout: 1)
        XCTAssertFalse(forcedReturned.value)

        original.cancel()
        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertFalse(forcedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertEqual(fixture.runtime.startedWhileCancelled, [false, false])

        fixture.runtime.resumeNext()
        let forcedOutcome = await forced.value
        XCTAssertTrue(forcedOutcome == .refreshed)
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertEqual(telemetry.count, 1)
        XCTAssertTrue(telemetry.first?.outcome == .refreshed)
        XCTAssertTrue(telemetry.first?.manual == true)
    }

    func testHandedOffForceKeepsOwnOutcomeWhenLaterForceFails() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "Cancelled owner result."),
                successSnapshot(used: 80),
                .error(provider: testProvider, message: "Later force failed."),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let handedOffStarted = expectation(description: "handed-off force started")
        let laterForceStarted = expectation(description: "later force started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { handedOffStarted.fulfill() }
            if count == 3 { laterForceStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        let forcedAEntered = expectation(description: "first force registered")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedAEntered.fulfill() }
        }
        let forcedA = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [forcedAEntered], timeout: 1)

        original.cancel()
        fixture.runtime.resumeNext()
        await fulfillment(of: [handedOffStarted], timeout: 1)

        let forcedBEntered = expectation(description: "later force registered")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedBEntered.fulfill() }
        }
        let forcedB = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [forcedBEntered], timeout: 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [laterForceStarted], timeout: 1)
        fixture.runtime.resumeNext()

        let originalOutcome = await original.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertTrue(forcedAOutcome == .refreshed)
        XCTAssertTrue(forcedBOutcome == .failed)
        XCTAssertEqual(fixture.runtime.refreshCount, 3)
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1)
        XCTAssertEqual(fixture.store.errorMessage(for: testProvider.id), "Later force failed.")
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testDisabledLaterForceDoesNotDowngradeCompletedForcedOutcome() async {
        let enabled = MutableFlag()
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 20), successSnapshot(used: 80)],
            isEnabled: { enabled.value }
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "first forced follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }

        var original: Task<WidgetDataStore.RefreshOutcome, Never>?
        fixture.store.onRefreshOutcome = { _, outcome, _, force in
            if force, outcome == .refreshed, fixture.runtime.refreshCount == 2 {
                // A completed successfully. Cancel its owner and disable before queued B can run.
                enabled.value = false
                original?.cancel()
            }
        }

        original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forcedAEntered = expectation(description: "first force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedAEntered.fulfill() }
        }
        let forcedA = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [forcedAEntered], timeout: 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)
        let forcedBEntered = expectation(description: "later force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedBEntered.fulfill() }
        }
        let forcedB = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [forcedBEntered], timeout: 1)
        fixture.runtime.resumeNext()

        let originalOutcome = await original?.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertTrue(forcedAOutcome == .refreshed, "later cleanup must preserve A's completed result")
        XCTAssertTrue(forcedBOutcome == .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testReservedHandOffDoesNotCreateOwnerlessSyntheticForce() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "Cancelled owner result."),
                successSnapshot(used: 80),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let handedOffStarted = expectation(description: "reserved hand-off refresh started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { handedOffStarted.fulfill() }
        }

        let handOffPaused = expectation(description: "reserved hand-off paused")
        var handOffContinuation: CheckedContinuation<Void, Never>?
        fixture.store.beforeRefreshHandOff = {
            handOffPaused.fulfill()
            await withCheckedContinuation { handOffContinuation = $0 }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let oldForceEntered = expectation(description: "old force registered")
        fixture.store.onRefreshJoined = { _, force in
            if force { oldForceEntered.fulfill() }
        }
        let oldForce = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        await fulfillment(of: [oldForceEntered], timeout: 1)

        original.cancel()
        fixture.runtime.resumeNext()
        await fulfillment(of: [handOffPaused], timeout: 1)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.contains(testProvider.id))

        let newForceEntered = expectation(description: "new force registered behind reservation")
        let ordinaryEntered = expectation(description: "ordinary caller registered behind reservation")
        fixture.store.onRefreshJoined = { _, force in
            (force ? newForceEntered : ordinaryEntered).fulfill()
        }
        let newForce = Task { await fixture.store.refresh(providerID: testProvider.id, force: true) }
        let ordinary = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [newForceEntered, ordinaryEntered], timeout: 1)

        oldForce.cancel()
        let oldForceOutcome = await oldForce.value
        handOffContinuation?.resume()
        handOffContinuation = nil

        await fulfillment(of: [handedOffStarted], timeout: 1)
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let newForceOutcome = await newForce.value
        let ordinaryOutcome = await ordinary.value

        XCTAssertTrue(originalOutcome == .skipped)
        XCTAssertTrue(oldForceOutcome == .skipped)
        XCTAssertTrue(newForceOutcome == .refreshed)
        XCTAssertTrue(ordinaryOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "cancelled old intent must not create a third request")
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1)
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }

    func testCancelledClaimedEnablementIntentIsHandedOff() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 40),
                successSnapshot(used: 90),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "enablement follow-up started")
        let handedOffStarted = expectation(description: "enablement intent handed off")
        let handedOffFinished = expectation(description: "handed-off refresh finished")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
            if count == 3 { handedOffStarted.fulfill() }
        }
        fixture.store.onRefreshOutcome = { _, outcome, _, force in
            if outcome == .refreshed, force, fixture.runtime.refreshCount == 3 {
                handedOffFinished.fulfill()
            }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        fixture.store.prepareProviderEnablementRefresh(for: testProvider.id)
        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)

        // Unlike waiter-backed intent, an enablement action remains meaningful without a waiting task.
        original.cancel()
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .skipped)

        await fulfillment(of: [handedOffStarted], timeout: 1)
        fixture.runtime.resumeNext()
        await fulfillment(of: [handedOffFinished], timeout: 1)

        XCTAssertEqual(fixture.runtime.refreshCount, 3)
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 90))
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }
}
