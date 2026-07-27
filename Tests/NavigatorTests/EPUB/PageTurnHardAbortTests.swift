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

        // Selection cleared: production must snap mid-page offsets back.
        navigator.spreadView(spreadView, selectionDidChange: nil, frame: .zero)
        #expect(navigator.currentSelection == nil)
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
