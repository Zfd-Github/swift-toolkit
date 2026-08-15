//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
@testable import ReadiumShared
import Testing
import UIKit

@MainActor
struct PageTurnHardAbortTests {
    @Test("hard-abort reserves mandatory recovery synchronously")
    func hardAbortReservesMandatoryRecoverySynchronously() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        var holdActiveLocate = true
        var locateCount = 0
        var executionOrder: [String] = []
        navigator.linkLocatorForTesting = { _ in
            locateCount += 1
            if locateCount == 1 {
                while holdActiveLocate {
                    if Task.isCancelled { return nil }
                    await Task.yield()
                }
            } else {
                executionOrder.append("absolute")
            }
            return nil
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            executionOrder.append("recovery")
            return true
        }

        let active = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        #expect(await waitUntil { locateCount == 1 })
        let navigation = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        #expect(await waitUntil {
            navigator.navigationQuiescenceDiagnosticsForTesting
                .contains("executorPending=1")
        })

        navigator.queueHardAbortRestoreForTesting(
            Locator(
                href: AnyURL(string: "chapter.xhtml")!,
                mediaType: .xhtml,
                locations: .init(progression: 0)
            )
        )

        // No yield: the mandatory request must already be visible to the
        // executor in this same MainActor turn.
        #expect(navigator.navigationQuiescenceDiagnosticsForTesting
            .contains("executorPending=2"))

        holdActiveLocate = false
        #expect(await !active.value)
        #expect(await !navigation.value)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(executionOrder == ["recovery", "absolute"])
    }

    @Test("ordinary hard-abort restore failure is fail-closed and reaches lease waiters")
    func ordinaryRestoreFailureIsFailClosed() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let original = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        let pagination = try #require(currentPaginationView(in: navigator))
        let originalGeneration = pagination.generation
        var holdRestore = true
        var restoreStarted = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            restoreStarted = true
            while holdRestore {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return false
        }
        navigator.queueHardAbortRestoreForTesting(original)
        #expect(await waitUntil { restoreStarted })
        let operation = NavigationOperation(
            operationID: 910,
            intent: .relative(.forward),
            timeout: .seconds(5)
        )
        let begin = Task { @MainActor in
            await navigator.beginPageTurnForTesting(
                to: .right,
                operation: operation
            )
        }

        holdRestore = false
        let result = await begin.value

        #expect(!result.isApplied)
        if case .spreadNotLoaded = result {
            // Expected terminal result from the failed stable restore.
        } else {
            Issue.record("Expected spreadNotLoaded, got \(result)")
        }
        #expect(pagination.generation > originalGeneration)
        #expect(navigator.isPageTurnControllerIdleForTesting)
    }

    @Test("selection clear queues its snap behind ordinary executor navigation")
    func selectionClearQueuesSnapBehindExecutorNavigation() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let pagination = try #require(currentPaginationView(in: navigator))
        let spread = try #require(pagination.currentView as? EPUBSpreadView)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        navigator.setNavigationOperationTimeoutForTesting(.seconds(1))
        var holdLocate = true
        var locateStarted = false
        var enteredLocatorMutation = false
        navigator.linkLocatorForTesting = { _ in
            locateStarted = true
            while holdLocate {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return target
        }
        navigator.pageTurnGoToIndexForTesting = { _ in
            enteredLocatorMutation = true
            return .applied
        }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        navigator.locatorNavigationLocationCalculationForTesting = {
            (target, nil)
        }
        let originalPaginationGeneration = pagination.generation
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let navigation = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        #expect(await waitUntil { locateStarted })
        let snapsBeforeClear = navigator.pageTurnSnapDocumentCountForTesting

        navigator.spreadView(spread, selectionDidChange: nil, frame: .zero)

        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeClear)
        #expect(navigator.hasPendingHardAbortRestoreForTesting)
        #expect(navigator.navigationQuiescenceDiagnosticsForTesting
            .contains("executorActive=1,executorPending=1"))
        holdLocate = false
        #expect(await navigation.value)
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        #expect(enteredLocatorMutation)
        #expect(elapsed < 500_000_000)
        #expect(pagination.generation == originalPaginationGeneration)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeClear + 1)
        #expect(navigator.pageTurnHardAbortSnapHadExecutorLeaseForTesting == true)
        #expect(navigator.isNavigationQuiescentForTesting)
        #expect(
            navigator.navigationQuiescenceDiagnosticsForTesting
                == "executorActive=0,executorPending=0,executorWaiters=0,recovery=0,recoveryWaiters=0,hardAbortPending=0,hardAbortWaiters=0,snapshotIdle=1"
        )
    }

    @Test("active navigation ignores multiple later recoveries which remain FIFO")
    func activeNavigationIgnoresMultipleLaterRecoveries() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var holdLocate = true
        var locateStarted = false
        var executionOrder: [String] = []
        var recoveryCount = 0
        navigator.linkLocatorForTesting = { _ in
            locateStarted = true
            while holdLocate {
                await Task.yield()
            }
            return target
        }
        navigator.pageTurnGoToIndexForTesting = { _ in
            executionOrder.append("A")
            return .applied
        }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        navigator.locatorNavigationLocationCalculationForTesting = {
            (target, nil)
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryCount += 1
            executionOrder.append("C\(recoveryCount)")
            return true
        }

        let navigation = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        #expect(await waitUntil { locateStarted })
        navigator.queueHardAbortRestoreForTesting(target)
        navigator.queueHardAbortRestoreForTesting(target)
        #expect(navigator.navigationQuiescenceDiagnosticsForTesting
            .contains("hardAbortPending=2"))

        holdLocate = false
        #expect(await navigation.value)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()

        #expect(executionOrder == ["A", "C1", "C2"])
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("recovery reserved before navigation cannot be bypassed")
    func earlierRecoveryRunsBeforeLaterNavigation() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var holdRecovery = true
        var recoveryStarted = false
        var executionOrder: [String] = []
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryStarted = true
            executionOrder.append("C")
            while holdRecovery {
                await Task.yield()
            }
            return true
        }
        navigator.linkLocatorForTesting = { _ in target }
        navigator.pageTurnGoToIndexForTesting = { _ in
            executionOrder.append("D")
            return .applied
        }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        navigator.locatorNavigationLocationCalculationForTesting = {
            (target, nil)
        }

        navigator.queueHardAbortRestoreForTesting(target)
        #expect(await waitUntil { recoveryStarted })
        let navigation = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        await Task.yield()
        #expect(executionOrder == ["C"])
        #expect(navigator.navigationQuiescenceDiagnosticsForTesting
            .contains("executorActive=1,executorPending=1"))

        holdRecovery = false
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(await navigation.value)

        #expect(executionOrder == ["C", "D"])
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("boundary waiter does not adopt a recovery reserved after it starts")
    func boundaryWaiterIgnoresNewerReservation() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var recoveryCount = 0
        var releaseFirst = false
        var releaseSecond = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryCount += 1
            let count = recoveryCount
            while count == 1 ? !releaseFirst : !releaseSecond {
                await Task.yield()
            }
            return true
        }

        navigator.queueHardAbortRestoreForTesting(target)
        #expect(await waitUntil { recoveryCount == 1 })
        let operation = NavigationOperation(
            operationID: 910,
            intent: .relative(.forward),
            timeout: .seconds(2)
        )
        var leaseResult: NavigationResult?
        let lease = Task { @MainActor in
            leaseResult = await navigator.awaitPageTurnNavigationLeaseForTesting(
                operation: operation
            )
        }
        #expect(await waitUntil {
            navigator.navigationQuiescenceDiagnosticsForTesting
                .contains("hardAbortWaiters=1")
        })

        // This reservation has a numerically lower executor ID than the
        // synthetic operation token, but it was submitted after the waiter's
        // dependency snapshot and therefore must not prolong that waiter.
        navigator.queueHardAbortRestoreForTesting(target)
        releaseFirst = true
        #expect(await waitUntil { recoveryCount == 2 })
        #expect(await waitUntil { leaseResult != nil })
        #expect(leaseResult?.isApplied == true)

        releaseSecond = true
        await lease.value
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("immediate recovery deadline leaves no pending reservation")
    func immediateRecoveryDeadlineLeavesNoPendingState() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var restoreStarted = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            restoreStarted = true
            return true
        }
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(0))

        navigator.queueHardAbortRestoreForTesting(target)

        #expect(!restoreStarted)
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("captured recovery failure survives suspension before boundary wait")
    func capturedRecoveryResultIsRetainedUntilBoundaryConsumesIt() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var recoveryStarted = false
        var releaseRecovery = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryStarted = true
            while !releaseRecovery {
                await Task.yield()
            }
            return false
        }
        var boundaryRegistered = false
        var releaseBoundarySuspension = false
        navigator.pageTurnLeaseAfterHardAbortRegistrationForTesting = {
            boundaryRegistered = true
            while !releaseBoundarySuspension {
                await Task.yield()
            }
        }

        navigator.queueHardAbortRestoreForTesting(target)
        #expect(await waitUntil { recoveryStarted })
        let operation = NavigationOperation(
            operationID: 910,
            intent: .relative(.forward),
            timeout: .seconds(2)
        )
        let lease = Task { @MainActor in
            await navigator.awaitPageTurnNavigationLeaseForTesting(
                operation: operation
            )
        }
        #expect(await waitUntil { boundaryRegistered })

        releaseRecovery = true
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)
        releaseBoundarySuspension = true
        let result = await lease.value

        if case .spreadNotLoaded = result {
            // The captured recovery's exact terminal result is retained.
        } else {
            Issue.record("Expected spreadNotLoaded, got \(result)")
        }
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("owner teardown cancels active and queued recovery reservations")
    func ownerTeardownDrainsRecoveryState() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var locateStarted = false
        navigator.linkLocatorForTesting = { _ in
            locateStarted = true
            while !Task.isCancelled {
                await Task.yield()
            }
            return nil
        }
        var recoveryBodyStartCount = 0
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryBodyStartCount += 1
            return true
        }

        let active = Task { @MainActor in
            await navigator.go(
                to: Link(href: "chapter.xhtml", mediaType: .xhtml),
                options: .none
            )
        }
        #expect(await waitUntil { locateStarted })
        navigator.queueHardAbortRestoreForTesting(target)
        navigator.queueHardAbortRestoreForTesting(target)
        let boundaryOperation = NavigationOperation(
            operationID: 910,
            intent: .relative(.forward),
            timeout: .seconds(2)
        )
        let boundary = Task { @MainActor in
            await navigator.awaitPageTurnNavigationLeaseForTesting(
                operation: boundaryOperation
            )
        }
        var ordinaryDrainFinished = false
        let ordinaryDrain = Task { @MainActor in
            await navigator.awaitPendingHardAbortLocationRestoreForTesting()
            ordinaryDrainFinished = true
        }
        #expect(await waitUntil {
            navigator.navigationQuiescenceDiagnosticsForTesting
                .contains("hardAbortPending=2,hardAbortWaiters=1")
        })

        navigator.cancelOwnedNavigationWorkForTesting()

        #expect(await !active.value)
        #expect(await boundary.value.isCancelled)
        await ordinaryDrain.value
        #expect(ordinaryDrainFinished)
        #expect(recoveryBodyStartCount == 0)
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("owner teardown discards a pan buffered behind recovery")
    func ownerTeardownDiscardsBufferedPan() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let target = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var recoveryStarted = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            recoveryStarted = true
            while !Task.isCancelled {
                await Task.yield()
            }
            return false
        }
        navigator.queueHardAbortRestoreForTesting(target)
        #expect(await waitUntil { recoveryStarted })
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -120,
            velocityX: -700
        )
        #expect(!navigator.isPageTurnIdleForTesting)

        navigator.cancelOwnedNavigationWorkForTesting()

        #expect(navigator.isPageTurnIdleForTesting)
        #expect(navigator.isNavigationQuiescentForTesting)
    }

    @Test("selection hard-abort defers document snap to the recovery executor")
    func selectionHardAbortDefersSnapToRecoveryExecutor() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        #expect(await navigator.beginPageTurnForTesting(to: .right))
        let snapsBeforeAbort = navigator.pageTurnSnapDocumentCountForTesting

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: true)

        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeAbort)
        #expect(navigator.hasPendingHardAbortRestoreForTesting)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeAbort + 1)
        #expect(navigator.pageTurnHardAbortSnapHadExecutorLeaseForTesting == true)
    }

    @Test("begin drains a queued hard-abort restore before opening a new session")
    func beginDrainsQueuedHardAbortRestoreBeforeNewSession() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        navigator.pageTurnDisplayFrameWaiterForTesting = {}

        let original = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .html,
            locations: .init(progression: 0.25)
        )
        var restoreStarted = false
        var restoreFinished = false
        var holdRestore = true
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            restoreStarted = true
            while holdRestore {
                if Task.isCancelled {
                    return false
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            restoreFinished = true
            return true
        }
        navigator.queueHardAbortRestoreForTesting(original)
        #expect(navigator.hasPendingHardAbortRestoreForTesting)

        // beginPageTurn must drain the queued restore before opening a session.
        let beginTask = Task { @MainActor in
            await navigator.beginPageTurnForTesting(to: .right)
        }
        #expect(await waitUntil { restoreStarted })
        #expect(!restoreFinished)

        holdRestore = false
        let didBegin = await beginTask.value
        #expect(restoreFinished)
        #expect(didBegin)
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)

        // Tear down the bare controller session opened by begin.
        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: true)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        await navigator.settlePageTurn()
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("selectionDidChange skips snap while selecting and snaps when cleared")
    func selectionDidChangeSnapPolicyMatchesHandles() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBSpreadView)
        let scrollView = spreadView.scrollView
        // Force multi-page content so mid-page offsets are meaningful if the
        // spread is loaded enough for snapToNearestHorizontalPage to run.
        scrollView.bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        scrollView.contentSize = CGSize(width: 1170, height: 844)
        let midPageOffset = CGPoint(x: 100, y: 0)
        scrollView.contentOffset = midPageOffset

        // In-flight turn so selection appear takes the hard-abort path.
        #expect(await navigator.beginPageTurnForTesting(to: .right))
        let snapsBeforeAppear = navigator.pageTurnSnapDocumentCountForTesting

        let selectionLocator = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .html,
            locations: .init(progression: 0.1)
        )
        // Real production delegate path (not the testing abort seam).
        navigator.spreadView(
            spreadView,
            selectionDidChange: selectionLocator,
            frame: CGRect(x: 10, y: 10, width: 40, height: 20)
        )

        #expect(navigator.currentSelection != nil)
        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeAppear)
        #expect(scrollView.contentOffset == midPageOffset)

        // Selection cleared: production must snap mid-page offsets back under
        // an executor lease.
        navigator.spreadView(spreadView, selectionDidChange: nil, frame: .zero)
        #expect(navigator.currentSelection == nil)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforeAppear + 1)

        // Pan path while selection is active: also must not snap.
        navigator.spreadView(
            spreadView,
            selectionDidChange: selectionLocator,
            frame: CGRect(x: 10, y: 10, width: 40, height: 20)
        )
        scrollView.contentOffset = midPageOffset
        #expect(await navigator.beginPageTurnForTesting(to: .right))
        let snapsBeforePan = navigator.pageTurnSnapDocumentCountForTesting
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        #expect(navigator.pageTurnSnapDocumentCountForTesting == snapsBeforePan)
        #expect(scrollView.contentOffset == midPageOffset)
        // Pan+selection hard-abort must release the turn even while selection
        // remains; do not OR with currentSelection (that would always pass).
        #expect(navigator.isPageTurnControllerIdleForTesting)
        #expect(navigator.isPageTurnIdleForTesting)

        navigator.spreadView(spreadView, selectionDidChange: nil, frame: .zero)
        #expect(navigator.currentSelection == nil)
        await navigator.settlePageTurn()
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("hard-abort restores run one after another never concurrently")
    func hardAbortRestoresSerializeWithoutConcurrentNavigation() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        navigator.pageTurnDisplayFrameWaiterForTesting = {}

        var activeRestores = 0
        var maxConcurrentRestores = 0
        var completedRestores = 0
        var holdFirstRestore = true
        var restoreEntryCount = 0
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            restoreEntryCount += 1
            let isFirstEntry = restoreEntryCount == 1
            activeRestores += 1
            maxConcurrentRestores = max(maxConcurrentRestores, activeRestores)
            if isFirstEntry {
                while holdFirstRestore {
                    if Task.isCancelled {
                        activeRestores -= 1
                        return false
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            activeRestores -= 1
            completedRestores += 1
            return true
        }

        let first = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .html,
            locations: .init(progression: 0.1)
        )
        let second = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .html,
            locations: .init(progression: 0.9)
        )
        navigator.queueHardAbortRestoreForTesting(first)
        #expect(await waitUntil { activeRestores == 1 })
        // Supersede while the first restore is still in flight — must not start
        // a second concurrent restorePageTurnLocator.
        navigator.queueHardAbortRestoreForTesting(second)
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(activeRestores == 1)
        #expect(completedRestores == 0)

        holdFirstRestore = false
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()

        #expect(maxConcurrentRestores == 1)
        #expect(completedRestores == 2)
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("pan during hard-abort restore buffers ended and does not stick mid-turn")
    func panDuringHardAbortRestoreBuffersTerminalAndReleases() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        navigator.pageTurnDisplayFrameWaiterForTesting = {}

        var holdRestore = true
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            while holdRestore {
                if Task.isCancelled { return false }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return true
        }
        navigator.queueHardAbortRestoreForTesting(
            Locator(
                href: AnyURL(string: "chapter.xhtml")!,
                mediaType: .html,
                locations: .init(progression: 0.2)
            )
        )
        #expect(navigator.hasPendingHardAbortRestoreForTesting)

        // Full pan while restore is outstanding: changed/ended must land in the
        // pending buffer, not open a terminal-less transaction.
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -120,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -120,
            velocityX: -700
        )
        #expect(navigator.hasPendingHardAbortRestoreForTesting)
        // No live surface transaction should be tracking without a terminal yet.
        #expect(navigator.isPageTurnControllerIdleForTesting
            || navigator.pageTurnPendingQueueCountForTesting >= 1)

        holdRestore = false
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
        await navigator.settlePageTurn()
        #expect(!navigator.hasPendingHardAbortRestoreForTesting)
        #expect(navigator.isPageTurnIdleForTesting)
    }
}

// MARK: - Helpers

@MainActor
private func makeMountedNavigator(
    pageTurnStyle: EPUBPageTurnStyle
) async throws -> EPUBNavigatorViewController {
    let link = Link(href: "chapter.xhtml", mediaType: .xhtml)
    let publication = Publication(
        manifest: Manifest(
            metadata: Metadata(title: "Test"),
            readingOrder: [link]
        ),
        container: SingleResourceContainer(
            resource: DataResource(string: "<html><body><p>Page</p></body></html>"),
            at: link.url()
        )
    )
    let navigator = try EPUBNavigatorViewController(
        publication: publication,
        initialLocation: nil,
        config: .init(pageTurnStyle: pageTurnStyle)
    )
    navigator.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    // Instant display frames — headless XCTest often never fires CADisplayLink.
    navigator.pageTurnDisplayFrameWaiterForTesting = {}
    navigator.loadViewIfNeeded()
    await navigator.initialized()
    navigator.view.layoutIfNeeded()
    return navigator
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 100 where !condition() {
        await Task.yield()
    }
    return condition()
}

@MainActor
private func currentPaginationView(
    in navigator: EPUBNavigatorViewController
) -> PaginationView? {
    navigator.view.subviews.compactMap { $0 as? PaginationView }.last
}
