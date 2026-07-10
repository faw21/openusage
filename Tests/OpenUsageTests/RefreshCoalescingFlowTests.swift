import XCTest
@testable import OpenUsage

extension RefreshCoalescingTests {
    func testNonForcedCallerJoinsActiveRefreshBeforeReturning() async {
        let fixture = makeFixture(snapshots: [successSnapshot(used: 40)])
        let firstStarted = expectation(description: "original refresh started")
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
            return outcome
        }
        await fulfillment(of: [joinedEntered], timeout: 1)
        XCTAssertFalse(joinedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        // The periodic-style caller was held until the active request produced current data; it did not
        // start a duplicate and could not continue into notification evaluation against the old snapshot.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let joinedOutcome = await joined.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(joinedOutcome == .refreshed)
        XCTAssertTrue(joinedReturned.value)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
    }

    func testConcurrentForcesCoalesceIntoOnePostFlightRefresh() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "The old key was rejected."),
                successSnapshot(used: 80),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "forced follow-up started")
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

        // Model an API-key save and a second click while the request that loaded the old key is suspended.
        // Both callers must join one queued follow-up rather than disappearing or starting overlapping I/O.
        let forcesEntered = expectation(description: "both forces entered the join path")
        forcesEntered.expectedFulfillmentCount = 2
        fixture.store.onRefreshJoined = { _, force in
            if force { forcesEntered.fulfill() }
        }
        let forcedA = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        let forcedB = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [forcesEntered], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [followUpStarted], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.contains(testProvider.id))

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .failed)
        XCTAssertTrue(forcedAOutcome == .refreshed)
        XCTAssertTrue(forcedBOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "a force burst must produce exactly one follow-up")
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 80))
        XCTAssertEqual(telemetry.count, 2)
        XCTAssertTrue(telemetry[0].outcome == .failed)
        XCTAssertFalse(telemetry[0].manual)
        XCTAssertTrue(telemetry[1].outcome == .refreshed)
        XCTAssertTrue(telemetry[1].manual)
    }

    func testForceDuringForcedFollowUpQueuesOneSequentialThirdRefresh() async {
        let fixture = makeFixture(
            snapshots: [
                successSnapshot(used: 20),
                successSnapshot(used: 60),
                .error(provider: testProvider, message: "Newest credential was rejected."),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let secondStarted = expectation(description: "first forced follow-up started")
        let thirdStarted = expectation(description: "second forced follow-up started")
        let forcedAReturned = expectation(description: "first force received its follow-up outcome")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.fulfill() }
            if count == 3 { thirdStarted.fulfill() }
        }
        var waiterReturnCount = 0

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let forcedAEntered = expectation(description: "first force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedAEntered.fulfill() }
        }
        let forcedA = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            waiterReturnCount += 1
            forcedAReturned.fulfill()
            return outcome
        }
        await fulfillment(of: [forcedAEntered], timeout: 1)

        fixture.runtime.resumeNext()
        await fulfillment(of: [secondStarted], timeout: 1)
        let forcedBEntered = expectation(description: "second force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            if force { forcedBEntered.fulfill() }
        }
        let forcedB = Task {
            let outcome = await fixture.store.refresh(providerID: testProvider.id, force: true)
            waiterReturnCount += 1
            return outcome
        }
        await fulfillment(of: [forcedBEntered], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertEqual(waiterReturnCount, 0)

        fixture.runtime.resumeNext()
        await fulfillment(of: [thirdStarted, forcedAReturned], timeout: 1)
        XCTAssertEqual(fixture.runtime.refreshCount, 3)
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1)
        XCTAssertEqual(waiterReturnCount, 1, "force A receives the request that consumed A's intent")

        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let forcedAOutcome = await forcedA.value
        let forcedBOutcome = await forcedB.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(forcedAOutcome == .refreshed)
        XCTAssertTrue(forcedBOutcome == .failed)
        XCTAssertEqual(waiterReturnCount, 2)
        XCTAssertEqual(fixture.runtime.refreshCount, 3, "the later force queues exactly one more request")
        XCTAssertEqual(fixture.runtime.maximumConcurrentRefreshCount, 1, "provider requests never overlap")
        XCTAssertEqual(fixture.store.errorMessage(for: testProvider.id), "Newest credential was rejected.")
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 60))
    }

    func testDelayedCredentialForceDoesNotPrequeueOwnerlessFollowUp() async {
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 40), successSnapshot(used: 80)]
        )
        let firstStarted = expectation(description: "original refresh started")
        let credentialRefreshStarted = expectation(description: "credential refresh started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { credentialRefreshStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        // API-key persistence is synchronous, but its forced refresh starts in a Task. Model the owner
        // finishing before that Task registers: saving a key has no separate enablement prequeue, so the
        // owner completes after one request and the delayed force becomes exactly the second request.
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)

        let credentialRefresh = Task {
            await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [credentialRefreshStarted], timeout: 1)
        fixture.runtime.resumeNext()

        let credentialOutcome = await credentialRefresh.value
        XCTAssertTrue(credentialOutcome == .refreshed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2, "one credential save must issue one fresh request")
    }

    func testPreparingEnablementDuringRequestQueuesImmediateFollowUp() async {
        let fixture = makeFixture(
            snapshots: [
                .error(provider: testProvider, message: "The old request failed."),
                successSnapshot(used: 65),
            ]
        )
        let firstStarted = expectation(description: "original refresh started")
        let followUpStarted = expectation(description: "enablement follow-up started")
        fixture.runtime.onStart = { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { followUpStarted.fulfill() }
        }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)

        // Re-enabling a provider calls this before the wake-driven pass. If the old request later fails,
        // it must not restore a backoff and swallow the user's request for an immediate probe.
        fixture.store.prepareProviderEnablementRefresh(for: testProvider.id)
        fixture.runtime.resumeNext()

        await fulfillment(of: [followUpStarted], timeout: 1)
        fixture.runtime.resumeNext()
        let outcome = await original.value

        XCTAssertTrue(outcome == .failed)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
        XCTAssertNil(fixture.store.errorMessage(for: testProvider.id))
        XCTAssertEqual(fixture.store.snapshots[testProvider.id]?.line(label: "Session"), sessionLine(used: 65))
    }

    func testDisableCancelsQueuedFollowUpAndReleasesWaitingCaller() async {
        let enabled = MutableFlag()
        let fixture = makeFixture(
            snapshots: [successSnapshot(used: 25)],
            isEnabled: { enabled.value }
        )
        let firstStarted = expectation(description: "original refresh started")
        fixture.runtime.onStart = { _ in firstStarted.fulfill() }

        let original = Task { await fixture.store.refresh(providerID: testProvider.id) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let joinedEntered = expectation(description: "ordinary joiner entered the join path")
        let forcedEntered = expectation(description: "force entered the join path")
        fixture.store.onRefreshJoined = { _, force in
            (force ? forcedEntered : joinedEntered).fulfill()
        }
        let joined = Task {
            return await fixture.store.refresh(providerID: testProvider.id)
        }
        let forced = Task {
            return await fixture.store.refresh(providerID: testProvider.id, force: true)
        }
        await fulfillment(of: [joinedEntered, forcedEntered], timeout: 1)

        enabled.value = false
        fixture.runtime.resumeNext()
        let originalOutcome = await original.value
        let joinedOutcome = await joined.value
        let forcedOutcome = await forced.value

        XCTAssertTrue(originalOutcome == .refreshed)
        XCTAssertTrue(joinedOutcome == .refreshed, "an ordinary joiner keeps the active request outcome")
        XCTAssertTrue(forcedOutcome == .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
        XCTAssertFalse(fixture.store.refreshingProviderIDs.contains(testProvider.id))
    }
}
