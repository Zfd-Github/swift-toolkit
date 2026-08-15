//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing

@MainActor
@Suite(.serialized)
struct NavigationOperationExecutorTests {
    @Test("operations are assigned increasing IDs and never overlap")
    func serialExecution() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var operationIDs: [UInt64] = []
        var activeCount = 0
        var maximumActiveCount = 0

        let first = Task { @MainActor in
            await executor.submit(intent: .relative(.forward), timeout: .seconds(1)) { operation in
                operationIDs.append(operation.operationID)
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                await gate.wait()
                activeCount -= 1
                return .applied
            }
        }
        await waitUntil { activeCount == 1 }

        let second = Task { @MainActor in
            await executor.submit(intent: .relative(.forward), timeout: .seconds(1)) { operation in
                operationIDs.append(operation.operationID)
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                activeCount -= 1
                return .applied
            }
        }
        await Task.yield()
        #expect(operationIDs.count == 1)

        gate.open()
        #expect(await (first.value).isApplied)
        #expect(await (second.value).isApplied)
        #expect(operationIDs == [1, 2])
        #expect(maximumActiveCount == 1)
        #expect(executor.activeOperationCountForTesting == 0)
    }

    @Test("latest absolute request supersedes an older queued absolute request")
    func absoluteLatestWins() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var startedTargets: [String] = []

        let blocker = Task { @MainActor in
            await executor.submit(intent: .relative(.forward), timeout: .seconds(1)) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let first = Task { @MainActor in
            await executor.submit(intent: .absolute("chapter-2"), timeout: .seconds(1)) { _ in
                startedTargets.append("chapter-2")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }
        let second = Task { @MainActor in
            await executor.submit(intent: .absolute("chapter-3"), timeout: .seconds(1)) { _ in
                startedTargets.append("chapter-3")
                return .applied
            }
        }

        #expect(await (first.value).isSuperseded)
        gate.open()
        #expect(await (blocker.value).isApplied)
        #expect(await (second.value).isApplied)
        #expect(startedTargets == ["chapter-3"])
    }

    @Test("relative queue keeps only the newest pending command")
    func relativeQueueIsBounded() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var startedDirections: [NavigationRelativeDirection] = []

        let blocker = Task { @MainActor in
            await executor.submit(intent: .absolute("chapter-1"), timeout: .seconds(1)) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let first = Task { @MainActor in
            await executor.submit(intent: .relative(.forward), timeout: .seconds(1)) { _ in
                startedDirections.append(.forward)
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }
        let second = Task { @MainActor in
            await executor.submit(intent: .relative(.backward), timeout: .seconds(1)) { _ in
                startedDirections.append(.backward)
                return .applied
            }
        }

        #expect(await (first.value).isSuperseded)
        #expect(executor.pendingOperationCountForTesting == 1)
        gate.open()
        #expect(await (blocker.value).isApplied)
        #expect(await (second.value).isApplied)
        #expect(startedDirections == [.backward])
    }

    @Test("hard-abort recovery cannot be coalesced by a later reload")
    func hardAbortRecoveryIsNotCoalescedByReload() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var executionOrder: [String] = []

        let blocker = Task { @MainActor in
            await executor.submit(
                intent: .absolute("blocker"),
                timeout: .seconds(1)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        // The mandatory restore body must run even if ordinary reload work is
        // queued while the blocker still owns the executor.
        let recovery = Task { @MainActor in
            await executor.submit(
                intent: .mustRunRecovery("hard-abort-restore"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("hard-abort-restore")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }

        let spreadReload = Task { @MainActor in
            await executor.submit(
                intent: .reload("spread-reload"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("spread-reload")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 2 }
        let snapshotReload = Task { @MainActor in
            await executor.submit(
                intent: .reload("snapshot-mutation"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("snapshot-mutation")
                return .applied
            }
        }
        #expect(await (spreadReload.value).isSuperseded)
        let settleReload = Task { @MainActor in
            await executor.submit(
                intent: .reload("settle-page-turn-recovery"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("settle-page-turn-recovery")
                return .applied
            }
        }
        #expect(await (snapshotReload.value).isSuperseded)
        gate.open()

        #expect(await (blocker.value).isApplied)
        #expect(await (recovery.value).isApplied)
        #expect(await (settleReload.value).isApplied)
        #expect(executionOrder == ["hard-abort-restore", "settle-page-turn-recovery"])
    }

    @Test("each must-run recovery retains its own queue entry")
    func mustRunRecoveriesDoNotCoalesceEachOther() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var executionOrder: [String] = []

        let blocker = Task { @MainActor in
            await executor.submit(
                intent: .absolute("blocker"),
                timeout: .seconds(1)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let first = Task { @MainActor in
            await executor.submit(
                intent: .mustRunRecovery("first"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("first")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }
        let second = Task { @MainActor in
            await executor.submit(
                intent: .mustRunRecovery("second"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("second")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 2 }
        gate.open()

        #expect(await (blocker.value).isApplied)
        #expect(await (first.value).isApplied)
        #expect(await (second.value).isApplied)
        #expect(executionOrder == ["first", "second"])
    }

    @Test("must-run recovery starts before an older queued reload")
    func mustRunRecoveryPreemptsQueuedReload() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var executionOrder: [String] = []

        let blocker = Task { @MainActor in
            await executor.submit(
                intent: .relative(.forward),
                timeout: .seconds(1)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let reload = Task { @MainActor in
            await executor.submit(
                intent: .reload("spread-reload"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("reload")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }
        let recovery = Task { @MainActor in
            await executor.submit(
                intent: .mustRunRecovery("hard-abort-restore"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("recovery")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 2 }
        gate.open()

        #expect(await (blocker.value).isApplied)
        #expect(await (recovery.value).isApplied)
        #expect(await (reload.value).isApplied)
        #expect(executionOrder == ["recovery", "reload"])
    }

    @Test("must-run recovery starts before an older queued absolute navigation")
    func mustRunRecoveryPreemptsQueuedAbsoluteNavigation() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var executionOrder: [String] = []

        let blocker = Task { @MainActor in
            await executor.submit(
                intent: .relative(.forward),
                timeout: .seconds(1)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let navigation = Task { @MainActor in
            await executor.submit(
                intent: .absolute("chapter-2"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("absolute")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }
        let recovery = Task { @MainActor in
            await executor.submit(
                intent: .mustRunRecovery("hard-abort-restore"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("recovery")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 2 }
        gate.open()

        #expect(await (blocker.value).isApplied)
        #expect(await (recovery.value).isApplied)
        #expect(await (navigation.value).isApplied)
        #expect(executionOrder == ["recovery", "absolute"])
    }

    @Test("mandatory reservation closes the active-release window before a reload")
    func mandatoryReservationClosesActiveReleaseWindowBeforeReload() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var executionOrder: [String] = []
        var recoveryPending = true

        let active = Task { @MainActor in
            await executor.submit(
                intent: .relative(.forward),
                timeout: .seconds(1)
            ) { operation in
                await operation.waitForCancellation()
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }
        let reload = Task { @MainActor in
            await executor.submit(
                intent: .reload("spread-reload"),
                timeout: .seconds(1)
            ) { _ in
                #expect(!recoveryPending)
                executionOrder.append("reload")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }

        let reservation = executor.reserve(
            intent: .mustRunRecovery("hard-abort-restore"),
            timeout: .seconds(1),
            completion: { _, _ in recoveryPending = false }
        ) { _ in
            executionOrder.append("recovery")
            return .applied
        }
        let recovery = Task { @MainActor in
            await executor.wait(for: reservation)
        }
        executor.abortActiveOperation()

        #expect(await (active.value).isCancelled)
        #expect(await (recovery.value).isApplied)
        #expect(await (reload.value).isApplied)
        #expect(!recoveryPending)
        #expect(executionOrder == ["recovery", "reload"])
    }

    @Test("mandatory reservation closes the active-release window before absolute navigation")
    func mandatoryReservationClosesActiveReleaseWindowBeforeAbsoluteNavigation() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var executionOrder: [String] = []

        let active = Task { @MainActor in
            await executor.submit(
                intent: .relative(.forward),
                timeout: .seconds(1)
            ) { operation in
                await operation.waitForCancellation()
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }
        let navigation = Task { @MainActor in
            await executor.submit(
                intent: .absolute("chapter-2"),
                timeout: .seconds(1)
            ) { _ in
                executionOrder.append("absolute")
                return .applied
            }
        }
        await waitUntil { executor.pendingOperationCountForTesting == 1 }

        let reservation = executor.reserve(
            intent: .mustRunRecovery("hard-abort-restore"),
            timeout: .seconds(1)
        ) { _ in
            executionOrder.append("recovery")
            return .applied
        }
        let recovery = Task { @MainActor in
            await executor.wait(for: reservation)
        }
        executor.abortActiveOperation()

        #expect(await (active.value).isCancelled)
        #expect(await (recovery.value).isApplied)
        #expect(await (navigation.value).isApplied)
        #expect(executionOrder == ["recovery", "absolute"])
    }

    @Test("reservation registration precedes even an immediate deadline completion")
    func reservationRegistrationPrecedesCompletion() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var registeredOperationID: UInt64?
        var completionObservedRegisteredID: UInt64?

        let reservation = executor.reserve(
            intent: .mustRunRecovery("immediate-deadline"),
            timeout: .milliseconds(0),
            registration: { operationID in
                registeredOperationID = operationID
            },
            completion: { operationID, _ in
                if registeredOperationID == operationID {
                    completionObservedRegisteredID = operationID
                }
            }
        ) { _ in
            Issue.record("An immediately expired reservation must not execute")
            return .applied
        }

        #expect(await executor.wait(for: reservation).isTimedOut)
        #expect(registeredOperationID == reservation.operationID)
        #expect(completionObservedRegisteredID == reservation.operationID)
    }

    @Test("shutdown cancels active and queued operations without starting pending bodies")
    func shutdownDrainsExecutorWithoutStartingPendingWork() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var pendingBodyStartCount = 0
        var completionResults: [NavigationResult] = []

        let active = Task { @MainActor in
            await executor.submit(
                intent: .absolute("active"),
                timeout: .seconds(2)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }
        let first = executor.reserve(
            intent: .mustRunRecovery("first"),
            timeout: .seconds(2),
            completion: { _, result in completionResults.append(result) }
        ) { _ in
            pendingBodyStartCount += 1
            return .applied
        }
        let second = executor.reserve(
            intent: .mustRunRecovery("second"),
            timeout: .seconds(2),
            completion: { _, result in completionResults.append(result) }
        ) { _ in
            pendingBodyStartCount += 1
            return .applied
        }

        executor.shutdown()

        #expect(await (active.value).isCancelled)
        #expect(await executor.wait(for: first).isCancelled)
        #expect(await executor.wait(for: second).isCancelled)
        #expect(pendingBodyStartCount == 0)
        #expect(completionResults.count == 2)
        for result in completionResults {
            #expect(result.isCancelled)
        }
        #expect(executor.waiterCountForTesting == 0)
        gate.open()
    }

    @Test("caller cancellation wins over a cancellation-insensitive body result")
    func cancellationCannotCompleteAsApplied() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()

        let submission = Task { @MainActor in
            await executor.submit(
                intent: .absolute("cancelled"),
                timeout: .seconds(2)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        submission.cancel()
        await Task.yield()
        gate.open()

        #expect(await (submission.value).isCancelled)
        #expect(executor.waiterCountForTesting == 0)
    }

    @Test("post-terminal cancellation wait returns the authoritative result")
    func postTerminalWaitReturnsImmediately() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var operation: NavigationOperation?
        let result = await executor.submit(
            intent: .absolute("complete"),
            timeout: .seconds(2)
        ) { activeOperation in
            operation = activeOperation
            return .applied
        }
        #expect(result.isApplied)
        let completedOperation = operation
        var postTerminalResult: NavigationResult?
        let waiter = Task { @MainActor in
            postTerminalResult = await completedOperation?.waitForCancellation()
        }

        await waitUntil { postTerminalResult != nil }
        #expect(postTerminalResult?.isApplied == true)
        await waiter.value
    }

    @Test("late body cannot reopen a terminal operation for detached recovery")
    func terminalOperationRejectsLateRecoveryRegistration() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var operation: NavigationOperation?
        var lateRecoveryObservedCancellation: Bool?

        let submission = Task { @MainActor in
            await executor.submit(
                intent: .absolute("late-body"),
                timeout: .seconds(2)
            ) { activeOperation in
                operation = activeOperation
                await gate.wait()
                activeOperation.beginRecovery()
                let lateRecovery = Task.detached { @MainActor in
                    for _ in 0 ..< 100 {
                        if Task.isCancelled { return true }
                        await Task.yield()
                    }
                    return Task.isCancelled
                }
                let recoveryID = activeOperation.registerRecoveryTask(lateRecovery)
                lateRecoveryObservedCancellation = await lateRecovery.value
                activeOperation.unregisterRecoveryTask(recoveryID)
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        executor.shutdown()
        #expect(await (submission.value).isCancelled)
        gate.open()
        await waitUntil { lateRecoveryObservedCancellation != nil }

        #expect(lateRecoveryObservedCancellation == true)
        #expect(operation?.phase == .terminal)
    }

    @Test("multiple reservation consumers all receive the terminal result")
    func reservationSupportsMultipleWaiters() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        let reservation = executor.reserve(
            intent: .absolute("shared-reservation"),
            timeout: .seconds(2)
        ) { _ in
            await gate.wait()
            return .applied
        }
        var firstResult: NavigationResult?
        var secondResult: NavigationResult?
        let first = Task { @MainActor in
            firstResult = await executor.wait(for: reservation)
        }
        let second = Task { @MainActor in
            secondResult = await executor.wait(for: reservation)
        }
        await Task.yield()

        gate.open()
        await waitUntil { firstResult != nil && secondResult != nil }

        #expect(firstResult?.isApplied == true)
        #expect(secondResult?.isApplied == true)
        await first.value
        await second.value
    }

    @Test("deadline includes time spent waiting in the queue")
    func queuedDeadlineExpires() async {
        let executor = NavigationOperationExecutor { _, _ in }
        let gate = ExecutorGate()
        var didRunExpiredBody = false

        let blocker = Task { @MainActor in
            await executor.submit(intent: .absolute("blocker"), timeout: .seconds(1)) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let expired = Task { @MainActor in
            await executor.submit(intent: .absolute("expired"), timeout: .milliseconds(20)) { _ in
                didRunExpiredBody = true
                return .applied
            }
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        gate.open()

        #expect(await (blocker.value).isApplied)
        #expect(await (expired.value).isTimedOut)
        #expect(!didRunExpiredBody)
        #expect(executor.pendingOperationCountForTesting == 0)
        #expect(executor.waiterCountForTesting == 0)
    }

    @Test("a cancellation-aware body observes the deadline after its lease is retired")
    func activeDeadlineWakesOperationWaiters() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var firstFinished = false
        var secondStarted = false

        let first = Task { @MainActor in
            await executor.submit(
                intent: .absolute("blocked"),
                timeout: .milliseconds(20)
            ) { operation in
                let result = await operation.waitForCancellation()
                firstFinished = true
                return result
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let second = Task { @MainActor in
            await executor.submit(
                intent: .absolute("next"),
                timeout: .seconds(1)
            ) { _ in
                secondStarted = true
                return .applied
            }
        }

        #expect(await (first.value).isTimedOut)
        await waitUntil { firstFinished }
        #expect(await (second.value).isApplied)
        #expect(secondStarted)
        #expect(executor.activeOperationCountForTesting == 0)
        #expect(executor.waiterCountForTesting == 0)
    }

    @Test("active deadline isolates and retires a lease even when its body ignores cancellation")
    func activeDeadlineRetiresNonCooperativeBody() async {
        let gate = ExecutorGate()
        var isolationResults: [NavigationResult] = []
        var secondStarted = false
        let executor = NavigationOperationExecutor { _, result in
            isolationResults.append(result)
        }

        let first = Task { @MainActor in
            await executor.submit(
                intent: .absolute("non-cooperative"),
                timeout: .milliseconds(20)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }

        let second = Task { @MainActor in
            await executor.submit(
                intent: .absolute("after-timeout"),
                timeout: .seconds(1)
            ) { _ in
                secondStarted = true
                return .applied
            }
        }

        let released = await pollUntil { secondStarted }
        #expect(released)
        #expect(await (first.value).isTimedOut)
        #expect(await (second.value).isApplied)
        #expect(isolationResults.count == 1)
        #expect(isolationResults.first?.isTimedOut == true)
        #expect(executor.activeOperationCountForTesting == 0)
        #expect(executor.waiterCountForTesting == 0)

        // Let the abandoned task unwind so the test leaves no suspended work.
        gate.open()
        await Task.yield()
    }

    @Test("owner abort isolates and retires a lease even when its body ignores cancellation")
    func ownerAbortRetiresNonCooperativeBody() async {
        let gate = ExecutorGate()
        var isolationResults: [NavigationResult] = []
        var secondStarted = false
        let executor = NavigationOperationExecutor { _, result in
            isolationResults.append(result)
        }

        let first = Task { @MainActor in
            await executor.submit(
                intent: .absolute("non-cooperative"),
                timeout: .seconds(1)
            ) { _ in
                await gate.wait()
                return .applied
            }
        }
        await waitUntil { executor.activeOperationCountForTesting == 1 }
        let second = Task { @MainActor in
            await executor.submit(
                intent: .absolute("after-abort"),
                timeout: .seconds(1)
            ) { _ in
                secondStarted = true
                return .applied
            }
        }

        executor.abortActiveOperation()
        let released = await pollUntil { secondStarted }
        gate.open()

        #expect(released)
        #expect(await (first.value).isCancelled)
        #expect(await (second.value).isApplied)
        #expect(isolationResults.count == 1)
        #expect(isolationResults.first?.isCancelled == true)
        #expect(executor.waiterCountForTesting == 0)
    }

    @Test("active deadline cancels registered recovery work")
    func activeDeadlineCancelsRegisteredRecoveryWork() async {
        let executor = NavigationOperationExecutor { _, _ in }
        var recoveryWasCancelled = false

        let result = await executor.submit(
            intent: .reload("recovery"),
            timeout: .milliseconds(20)
        ) { operation in
            operation.beginRecovery()
            let recovery = Task.detached { @MainActor in
                while !Task.isCancelled {
                    await Task.yield()
                }
                recoveryWasCancelled = true
            }
            let recoveryID = operation.registerRecoveryTask(recovery)
            let result = await operation.waitForCancellation()
            await recovery.value
            operation.unregisterRecoveryTask(recoveryID)
            return result
        }

        #expect(result.isTimedOut)
        #expect(recoveryWasCancelled)
        #expect(executor.activeOperationCountForTesting == 0)
    }

    @Test("timed-out mutation recovery cannot extend the original absolute deadline")
    func timedOutMutationRecoveryCannotExtendAbsoluteDeadline() async {
        let operation = NavigationOperation(
            operationID: 77,
            intent: .absolute("recovery"),
            timeout: .milliseconds(1)
        )
        let originalDeadline = operation.deadlineUptimeNanoseconds
        try? await Task.sleep(nanoseconds: 2_000_000)
        #expect(operation.check()?.isTimedOut == true)

        operation.cancel(as: .timedOut)
        operation.beginRecovery()

        #expect(operation.operationID == 77)
        #expect(operation.phase == .recovering)
        #expect(operation.deadlineUptimeNanoseconds == originalDeadline)
        #expect(operation.remainingNanoseconds == 0)
        #expect(operation.check()?.isTimedOut == true)
    }

    @Test("cancelled mutation recovery uses only the original deadline remainder")
    func cancelledMutationRecoveryUsesOriginalDeadlineRemainder() async {
        let operation = NavigationOperation(
            operationID: 78,
            intent: .reload("hard-abort"),
            timeout: .milliseconds(40)
        )
        let originalDeadline = operation.deadlineUptimeNanoseconds
        try? await Task.sleep(nanoseconds: 5_000_000)
        operation.cancel()
        #expect(operation.check()?.isCancelled == true)

        operation.beginRecovery()

        #expect(operation.operationID == 78)
        #expect(operation.deadlineUptimeNanoseconds == originalDeadline)
        #expect(operation.check() == nil)
        try? await Task.sleep(nanoseconds: 45_000_000)
        #expect(operation.check()?.isTimedOut == true)
    }
}

@MainActor
private final class ExecutorGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0 ..< 500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

@MainActor
private func pollUntil(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}
