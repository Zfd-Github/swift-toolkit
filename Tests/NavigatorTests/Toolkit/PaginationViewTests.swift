//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import UIKit

@MainActor
private final class StubPageView: UIView, PageView {
    func go(to location: PageLocation, animated: Bool) async {}
}

@MainActor
private final class StubPaginationDelegate: PaginationViewDelegate {
    let views: [Int: StubPageView]
    var unavailableIndices: Set<Int> = []
    var viewportUpdateCount = 0
    var verticalOffsetResolver: ((PageLocation, Int) async throws -> CGFloat?)?

    init(pageCount: Int) {
        views = Dictionary(uniqueKeysWithValues: (0 ..< pageCount).map { ($0, StubPageView()) })
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        guard !unavailableIndices.contains(index) else {
            return nil
        }
        return views[index]
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {}

    func paginationViewDidUpdateViewport(_ paginationView: PaginationView) {
        viewportUpdateCount += 1
    }

    func paginationView(
        _ paginationView: PaginationView,
        verticalOffsetFor location: PageLocation,
        at index: Int
    ) async throws -> CGFloat? {
        try await verticalOffsetResolver?(location, index)
    }

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        0
    }
}

private enum VerticalOffsetTestError: Error {
    case failed
}

@MainActor
private final class SuspendedVerticalOffsetResolver {
    private var continuation: CheckedContinuation<CGFloat?, Never>?
    private(set) var isResolving = false

    func resolve(_ location: PageLocation, at index: Int) async -> CGFloat? {
        isResolving = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(returning value: CGFloat?) {
        isResolving = false
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class SuspendedPageView: UIView, PageView {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var goCallCount = 0

    func go(to location: PageLocation, animated: Bool) async {
        goCallCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class LoadingPaginationDelegate: PaginationViewDelegate {
    let suspendedView: SuspendedPageView
    let immediateViews: [Int: StubPageView]
    var factoryIndices: [Int] = []
    var viewsUpdateCount = 0

    init(pageCount: Int, suspendedIndex: Int) {
        suspendedView = SuspendedPageView()
        immediateViews = Dictionary(uniqueKeysWithValues: (0 ..< pageCount).compactMap { index in
            index == suspendedIndex ? nil : (index, StubPageView())
        })
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        factoryIndices.append(index)
        return immediateViews[index] ?? suspendedView
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        viewsUpdateCount += 1
    }

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        0
    }
}

@MainActor
private final class NavigationResultRecorder {
    var result: Bool?
}

@MainActor
struct PaginationViewTests {
    @Test("continuous resources use measured heights and can share the viewport")
    func continuousGeometry() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 3, currentIndex: 1)
        defer { withExtendedLifetime(delegate) {} }

        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(900, isReady: true, at: 1)
        paginationView.setVerticalPageHeight(700, isReady: true, at: 2)
        paginationView.layoutIfNeeded()

        #expect(paginationView.frameForView(at: 0) == CGRect(x: 0, y: 0, width: 320, height: 600))
        #expect(paginationView.frameForView(at: 1) == CGRect(x: 0, y: 600, width: 320, height: 900))
        #expect(paginationView.frameForView(at: 2) == CGRect(x: 0, y: 1500, width: 320, height: 700))
        #expect(paginationView.contentSize == CGSize(width: 320, height: 2200))

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 500

        #expect(paginationView.visibleIndices == [0, 1])
        #expect(paginationView.visibleFrame(at: 0) == CGRect(x: 0, y: 500, width: 320, height: 100))
        #expect(paginationView.visibleFrame(at: 1) == CGRect(x: 0, y: 0, width: 320, height: 400))
    }

    @Test("effective viewport excludes all adjusted content insets")
    func adjustedInsetsGeometry() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 1, currentIndex: 0)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 0)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentInset = UIEdgeInsets(top: 20, left: 10, bottom: 30, right: 15)
        scrollView.contentOffset = CGPoint(x: 0, y: 80)

        #expect(paginationView.visibleFrame(at: 0) == CGRect(x: 10, y: 100, width: 295, height: 450))
    }

    @Test("an unready neighbor does not extend scrollable content")
    func unreadyNeighbor() async {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 0)
        defer { withExtendedLifetime(delegate) {} }

        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(900, isReady: false, at: 1)
        paginationView.layoutIfNeeded()

        #expect(paginationView.contentSize.height == 600)
        #expect(paginationView.frameForView(at: 1) == nil)
    }

    @Test("shrinking ready content clamps a bottom viewport")
    func bottomOffsetIsClamped() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 1)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 700
        paginationView.setVerticalPageHeight(100, isReady: true, at: 1)

        #expect(paginationView.contentSize.height == 700)
        #expect(scrollView.contentOffset.y == 200)
    }

    @Test("a ready prepend preserves the first visible resource anchor")
    func prependPreservesAnchor() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 5, currentIndex: 2)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(500, isReady: false, at: 1)
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 2)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 3)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 300
        #expect(paginationView.visibleFrame(at: 2)?.minY == 300)

        paginationView.setVerticalPageHeight(500, isReady: true, at: 1)

        #expect(paginationView.frameForView(at: 2)?.minY == 500)
        #expect(paginationView.visibleFrame(at: 2)?.minY == 300)
        #expect(scrollView.contentOffset.y == 800)
    }

    @Test("evicting ready content above the viewport preserves its anchor")
    func upperEvictionPreservesAnchor() async throws {
        let (paginationView, delegate) = await makePagination(
            pageCount: 7,
            currentIndex: 2,
            preloadPreviousPositionCount: 1,
            preloadNextPositionCount: 1
        )
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 2)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 3)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 1250

        #expect(paginationView.currentIndex == 3)
        #expect(paginationView.loadedViews[1] == nil)
        #expect(paginationView.visibleFrame(at: 3)?.minY == 50)
        #expect(scrollView.contentOffset.y == 650)
    }

    @Test("a resource height change above the viewport preserves its anchor")
    func heightChangePreservesAnchor() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 1)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(900, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 1000
        #expect(paginationView.visibleFrame(at: 1)?.minY == 100)

        paginationView.setVerticalPageHeight(4800, isReady: true, at: 0)

        #expect(paginationView.visibleFrame(at: 1)?.minY == 100)
        #expect(scrollView.contentOffset.y == 4900)
    }

    @Test("a visible resource reflow preserves its proportional anchor")
    func visibleResourceReflowPreservesProportionalAnchor() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 1, currentIndex: 0)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 0)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 250

        paginationView.setVerticalPageHeight(2000, isReady: false, at: 0)

        #expect(scrollView.contentOffset.y == 500)
    }

    @Test("continuous mode preloads neighbors when positions are unavailable")
    func noPositionsStillPreloadsNeighbors() async {
        let (paginationView, delegate) = await makePagination(
            pageCount: 5,
            currentIndex: 2,
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(paginationView.loadedViews.keys.sorted() == [1, 2, 3])
    }

    @Test("a fifty-resource publication keeps only the configured window")
    func windowIsBounded() async {
        let (paginationView, delegate) = await makePagination(
            pageCount: 50,
            currentIndex: 25,
            preloadPreviousPositionCount: 2,
            preloadNextPositionCount: 6
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(paginationView.loadedViews.keys.sorted() == Array(23 ... 31))
    }

    @Test("vertical RTL resources retain reading order")
    func verticalRTLReadingOrder() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 3, currentIndex: 1, readingProgression: .rtl)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        paginationView.setVerticalPageHeight(600, isReady: true, at: 2)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 500

        #expect(paginationView.frameForView(at: 0)?.minY == 0)
        #expect(paginationView.frameForView(at: 1)?.minY == 600)
        #expect(paginationView.frameForView(at: 2)?.minY == 1200)
        #expect(paginationView.visibleIndices == [0, 1])
        #expect(
            paginationView.orderedViews.map { ObjectIdentifier($0) }
                == [0, 1, 2].map { ObjectIdentifier(delegate.views[$0]!) }
        )
    }

    @Test("horizontal pagination geometry remains unchanged")
    func horizontalBaseline() async {
        let pageCount = 3
        let delegate = StubPaginationDelegate(pageCount: pageCount)
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            preloadPreviousPositionCount: 3,
            preloadNextPositionCount: 3,
            isScrollEnabled: true
        )
        paginationView.delegate = delegate
        paginationView.reloadAtIndex(1, location: .start, pageCount: pageCount, readingProgression: .ltr)
        await waitUntil { paginationView.loadedViews.count == pageCount }
        paginationView.layoutIfNeeded()

        #expect(paginationView.axis == .horizontalPaged)
        #expect(paginationView.contentSize == CGSize(width: 960, height: 500))
        #expect(paginationView.frameForView(at: 0) == CGRect(x: 0, y: 0, width: 320, height: 500))
        #expect(paginationView.frameForView(at: 1) == CGRect(x: 320, y: 0, width: 320, height: 500))
        #expect(paginationView.frameForView(at: 2) == CGRect(x: 640, y: 0, width: 320, height: 500))
        #expect(paginationView.visibleIndices == [1])

        paginationView.reloadAtIndex(1, location: .start, pageCount: pageCount, readingProgression: .rtl)
        await waitUntil { paginationView.loadedViews.count == pageCount }
        paginationView.layoutIfNeeded()

        #expect(paginationView.contentSize == CGSize(width: 960, height: 500))
        #expect(paginationView.frameForView(at: 0) == CGRect(x: 640, y: 0, width: 320, height: 500))
        #expect(paginationView.frameForView(at: 1) == CGRect(x: 320, y: 0, width: 320, height: 500))
        #expect(paginationView.frameForView(at: 2) == CGRect(x: 0, y: 0, width: 320, height: 500))
        #expect(paginationView.visibleIndices == [1])
        #expect(
            paginationView.orderedViews.map { ObjectIdentifier($0) }
                == [2, 1, 0].map { ObjectIdentifier(delegate.views[$0]!) }
        )
    }

    @Test("same-resource scrolling emits one throttled viewport update")
    func viewportUpdatesAreThrottled() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 1, currentIndex: 0)
        paginationView.setVerticalPageHeight(2000, isReady: true, at: 0)
        paginationView.layoutIfNeeded()
        await nextMainRunLoop()
        delegate.viewportUpdateCount = 0

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 100
        scrollView.contentOffset.y = 200
        scrollView.contentOffset.y = 300
        await nextMainRunLoop()

        #expect(paginationView.currentIndex == 0)
        #expect(delegate.viewportUpdateCount == 1)
    }

    @Test("backward navigation aligns the previous resource end inside the effective viewport")
    func backwardNavigationKeepsPreviousResourceEndVisible() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 1)
        delegate.verticalOffsetResolver = { location, _ in
            switch location {
            case .start:
                return 0
            case .end:
                return 1000
            case .locator:
                return nil
            }
        }
        paginationView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 30, right: 0)
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 1)
        paginationView.layoutIfNeeded()
        await nextMainRunLoop()

        let moved = await paginationView.goToIndex(
            0,
            location: .end,
            options: .init(animated: false)
        )

        let scrollView = try #require(outerScrollView(in: paginationView))
        #expect(moved)
        #expect(scrollView.contentOffset.y == 530)
        #expect(paginationView.visibleIndices == [0])
        #expect(paginationView.visibleFrame(at: 0) == CGRect(x: 0, y: 550, width: 320, height: 450))
    }

    @Test("the resource containing viewport center remains current at a long-short boundary")
    func viewportCenterSelectsContainingResource() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 3, currentIndex: 0)
        paginationView.setVerticalPageHeight(2000, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(100, isReady: true, at: 1)
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 2)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 1650

        #expect(paginationView.currentIndex == 0)
        #expect(paginationView.currentView === delegate.views[0])

        scrollView.contentOffset.y = 1800

        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
    }

    @Test("cancelling one ready waiter does not cancel another waiter for the same resource")
    func verticalReadyWaiterCancellationIsScoped() async {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 0)
        delegate.verticalOffsetResolver = { _, _ in 0 }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(600, isReady: false, at: 1)

        let cancelledRecorder = NavigationResultRecorder()
        let cancelledTask = Task { @MainActor in
            cancelledRecorder.result = await paginationView.goToIndex(
                1,
                location: .start,
                options: .init(animated: false)
            )
        }
        await nextMainRunLoop()

        let readyRecorder = NavigationResultRecorder()
        let readyTask = Task { @MainActor in
            readyRecorder.result = await paginationView.goToIndex(
                1,
                location: .start,
                options: .init(animated: false)
            )
        }
        await nextMainRunLoop()

        cancelledTask.cancel()
        await waitUntil { cancelledRecorder.result != nil }

        #expect(cancelledRecorder.result == false)
        #expect(readyRecorder.result == nil)

        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        _ = await cancelledTask.value
        _ = await readyTask.value

        #expect(readyRecorder.result == true)
    }

    @Test("a failed vertical target preserves the current page and can be retried")
    func verticalNavigationRollsBackAndRetriesAfterFactoryFailure() async throws {
        let (paginationView, delegate) = await makePagination(
            pageCount: 2,
            currentIndex: 0,
            unavailableIndices: [1]
        )
        defer { withExtendedLifetime(delegate) {} }
        delegate.verticalOffsetResolver = { _, _ in 0 }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 0)
        paginationView.layoutIfNeeded()

        let originalFrame = try #require(paginationView.frameForView(at: 0))

        let firstResult = await paginationView.goToIndex(
            1,
            location: .start,
            options: .init(animated: false)
        )

        #expect(firstResult == false)
        #expect(paginationView.currentIndex == 0)
        #expect(paginationView.currentView === delegate.views[0])
        #expect(paginationView.frameForView(at: 0) == originalFrame)
        #expect(delegate.views[0]?.isHidden == false)

        delegate.unavailableIndices.remove(1)

        let recorder = NavigationResultRecorder()
        let navigationTask = Task { @MainActor in
            recorder.result = await paginationView.goToIndex(
                1,
                location: .start,
                options: .init(animated: false)
            )
        }

        await waitUntil { paginationView.loadedViews[1] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 1)
        _ = await navigationTask.value

        #expect(recorder.result == true)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
    }

    @Test("a provisional vertical target survives viewport updates until it commits")
    func provisionalVerticalTargetSurvivesViewportUpdates() async throws {
        let (paginationView, delegate) = await makePagination(
            pageCount: 5,
            currentIndex: 1,
            preloadPreviousPositionCount: 1,
            preloadNextPositionCount: 1
        )
        defer { withExtendedLifetime(delegate) {} }
        delegate.verticalOffsetResolver = { _, _ in 0 }
        for index in 0 ... 2 {
            paginationView.setVerticalPageHeight(600, isReady: true, at: index)
        }
        paginationView.layoutIfNeeded()

        let recorder = NavigationResultRecorder()
        let navigationTask = Task { @MainActor in
            recorder.result = await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 1200

        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.loadedViews[4] === delegate.views[4])

        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)
        _ = await navigationTask.value

        #expect(recorder.result == true)
        #expect(paginationView.currentIndex == 4)
        #expect(paginationView.currentView === delegate.views[4])
    }

    @Test("a nil vertical offset preserves the current window and the target can be retried")
    func nilVerticalOffsetDoesNotCommit() async throws {
        let (paginationView, delegate) = await makePagination(
            pageCount: 5,
            currentIndex: 1,
            preloadPreviousPositionCount: 1,
            preloadNextPositionCount: 1
        )
        defer { withExtendedLifetime(delegate) {} }
        for index in 0 ... 2 {
            paginationView.setVerticalPageHeight(600, isReady: true, at: index)
        }
        paginationView.layoutIfNeeded()

        let originalLoadedIndices = paginationView.loadedViews.keys.sorted()
        let originalFrames = Dictionary(uniqueKeysWithValues: originalLoadedIndices.compactMap { index in
            paginationView.frameForView(at: index).map { (index, $0) }
        })
        let originalContentSize = paginationView.contentSize
        delegate.verticalOffsetResolver = { _, _ in nil }

        let failedNavigation = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)

        #expect(await failedNavigation.value == false)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
        #expect(paginationView.loadedViews.keys.sorted() == originalLoadedIndices)
        #expect(paginationView.contentSize == originalContentSize)
        for (index, frame) in originalFrames {
            #expect(paginationView.frameForView(at: index) == frame)
        }

        delegate.verticalOffsetResolver = { _, _ in 0 }
        let retry = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)

        #expect(await retry.value == true)
        #expect(paginationView.currentIndex == 4)
        #expect(paginationView.currentView === delegate.views[4])
    }

    @Test("cancelling vertical offset resolution preserves the current window and permits retry")
    func cancelledVerticalOffsetDoesNotCommit() async {
        let (paginationView, delegate) = await makePagination(
            pageCount: 5,
            currentIndex: 1,
            preloadPreviousPositionCount: 1,
            preloadNextPositionCount: 1
        )
        defer { withExtendedLifetime(delegate) {} }
        for index in 0 ... 2 {
            paginationView.setVerticalPageHeight(600, isReady: true, at: index)
        }
        paginationView.layoutIfNeeded()

        let originalLoadedIndices = paginationView.loadedViews.keys.sorted()
        let originalFrames = Dictionary(uniqueKeysWithValues: originalLoadedIndices.compactMap { index in
            paginationView.frameForView(at: index).map { (index, $0) }
        })
        let originalContentSize = paginationView.contentSize
        let resolver = SuspendedVerticalOffsetResolver()
        delegate.verticalOffsetResolver = resolver.resolve

        let navigation = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)
        await waitUntil { resolver.isResolving }

        navigation.cancel()
        resolver.resume(returning: 0)

        #expect(await navigation.value == false)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
        #expect(paginationView.loadedViews.keys.sorted() == originalLoadedIndices)
        #expect(paginationView.contentSize == originalContentSize)
        for (index, frame) in originalFrames {
            #expect(paginationView.frameForView(at: index) == frame)
        }

        delegate.verticalOffsetResolver = { _, _ in 0 }
        let retry = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)

        #expect(await retry.value == true)
        #expect(paginationView.currentIndex == 4)
    }

    @Test("a thrown vertical offset resolution preserves the current window and permits retry")
    func thrownVerticalOffsetDoesNotCommit() async throws {
        let (paginationView, delegate) = await makePagination(
            pageCount: 5,
            currentIndex: 1,
            preloadPreviousPositionCount: 1,
            preloadNextPositionCount: 1
        )
        defer { withExtendedLifetime(delegate) {} }
        for index in 0 ... 2 {
            paginationView.setVerticalPageHeight(600, isReady: true, at: index)
        }
        paginationView.layoutIfNeeded()

        let originalLoadedIndices = paginationView.loadedViews.keys.sorted()
        let originalFrames = Dictionary(uniqueKeysWithValues: originalLoadedIndices.compactMap { index in
            paginationView.frameForView(at: index).map { (index, $0) }
        })
        let originalContentSize = paginationView.contentSize
        delegate.verticalOffsetResolver = { _, _ in
            throw VerticalOffsetTestError.failed
        }

        let failedNavigation = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)

        #expect(await failedNavigation.value == false)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
        #expect(paginationView.loadedViews.keys.sorted() == originalLoadedIndices)
        #expect(paginationView.contentSize == originalContentSize)
        for (index, frame) in originalFrames {
            #expect(paginationView.frameForView(at: index) == frame)
        }

        delegate.verticalOffsetResolver = { _, _ in 0 }
        let retry = Task { @MainActor in
            await paginationView.goToIndex(
                4,
                location: .start,
                options: .init(animated: false)
            )
        }
        await waitUntil { paginationView.loadedViews[4] != nil }
        paginationView.setVerticalPageHeight(600, isReady: true, at: 4)

        #expect(await retry.value == true)
        #expect(paginationView.currentIndex == 4)
    }

    @Test("removing pagination stops a resumed preload queue")
    func removalInvalidatesPreloadQueue() async {
        let delegate = LoadingPaginationDelegate(pageCount: 3, suspendedIndex: 0)
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 2,
            isScrollEnabled: true
        )
        paginationView.delegate = delegate
        let hostView = UIView()
        hostView.addSubview(paginationView)
        paginationView.reloadAtIndex(
            0,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )
        await waitUntil { delegate.suspendedView.goCallCount == 1 }

        paginationView.removeFromSuperview()
        delegate.suspendedView.resume()
        await nextMainRunLoop()
        await nextMainRunLoop()

        #expect(delegate.factoryIndices == [0])
        #expect(delegate.viewsUpdateCount == 0)
    }

    @Test("reloading pagination ignores completion from the previous generation")
    func reloadInvalidatesPreviousLoadingGeneration() async {
        let delegate = LoadingPaginationDelegate(pageCount: 3, suspendedIndex: 0)
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        paginationView.delegate = delegate
        paginationView.reloadAtIndex(
            0,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )
        await waitUntil { delegate.suspendedView.goCallCount == 1 }

        paginationView.reloadAtIndex(
            2,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )
        await waitUntil { delegate.factoryIndices.contains(2) }
        await waitUntil { delegate.viewsUpdateCount == 1 }

        delegate.suspendedView.resume()
        await nextMainRunLoop()
        await nextMainRunLoop()

        #expect(delegate.factoryIndices == [0, 2])
        #expect(delegate.viewsUpdateCount == 1)
        #expect(paginationView.currentIndex == 2)
    }

    @Test("reflow recomputes the resource containing the restored viewport center")
    func reflowRecomputesCurrentIndex() async throws {
        let (paginationView, delegate) = await makePagination(pageCount: 2, currentIndex: 0)
        defer { withExtendedLifetime(delegate) {} }
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 0)
        paginationView.setVerticalPageHeight(1000, isReady: true, at: 1)
        paginationView.layoutIfNeeded()

        let scrollView = try #require(outerScrollView(in: paginationView))
        scrollView.contentOffset.y = 600
        #expect(paginationView.currentIndex == 0)

        paginationView.setVerticalPageHeight(500, isReady: true, at: 0)

        #expect(scrollView.contentOffset.y == 300)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.currentView === delegate.views[1])
    }

    private func makePagination(
        pageCount: Int,
        currentIndex: Int,
        preloadPreviousPositionCount: Int = 10,
        preloadNextPositionCount: Int = 10,
        readingProgression: ReadiumNavigator.ReadingProgression = .ltr,
        unavailableIndices: Set<Int> = []
    ) async -> (PaginationView, StubPaginationDelegate) {
        let delegate = StubPaginationDelegate(pageCount: pageCount)
        delegate.unavailableIndices = unavailableIndices
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 500),
            preloadPreviousPositionCount: preloadPreviousPositionCount,
            preloadNextPositionCount: preloadNextPositionCount,
            isScrollEnabled: true,
            axis: .verticalContinuous
        )
        paginationView.delegate = delegate
        paginationView.reloadAtIndex(
            currentIndex,
            location: .start,
            pageCount: pageCount,
            readingProgression: readingProgression
        )
        let firstIndex = max(0, currentIndex - max(1, preloadPreviousPositionCount))
        let lastIndex = min(pageCount - 1, currentIndex + max(1, preloadNextPositionCount))
        let expectedLoadedCount = (firstIndex ... lastIndex)
            .filter { !unavailableIndices.contains($0) }
            .count
        await waitUntil { paginationView.loadedViews.count == expectedLoadedCount }
        paginationView.layoutIfNeeded()
        return (paginationView, delegate)
    }

    private func outerScrollView(in paginationView: PaginationView) -> UIScrollView? {
        paginationView.subviews.compactMap { $0 as? UIScrollView }.first
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
