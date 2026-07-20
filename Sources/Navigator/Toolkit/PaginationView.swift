//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation, animated: Bool) async
}

@MainActor
protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Called when the viewport changed, including within the current page view.
    func paginationViewDidUpdateViewport(_ paginationView: PaginationView)

    /// Resolves a page location to a resource-local vertical offset.
    func paginationView(
        _ paginationView: PaginationView,
        verticalOffsetFor location: PageLocation,
        at index: Int
    ) async throws -> CGFloat?

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

extension PaginationViewDelegate {
    func paginationViewDidUpdateViewport(_ paginationView: PaginationView) {}

    func paginationView(
        _ paginationView: PaginationView,
        verticalOffsetFor location: PageLocation,
        at index: Int
    ) async -> CGFloat? {
        nil
    }
}

final class PaginationView: UIView, Loggable {
    enum Axis: Equatable {
        case horizontalPaged
        case verticalContinuous
    }

    private struct VerticalPageState {
        var height: CGFloat
        var isReady: Bool
    }

    private enum VerticalPageReadyResult {
        case ready
        case unavailable
    }

    private struct VerticalPageReadyWaiter {
        let id: UUID
        let continuation: CheckedContinuation<VerticalPageReadyResult, Never>
    }

    private struct ViewportAnchor {
        var index: Int
        var localY: CGFloat
    }

    weak var delegate: PaginationViewDelegate?

    private(set) var axis: Axis

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int

    /// Queue of page index to be loaded next.
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []

    private var verticalPageStates: [Int: VerticalPageState] = [:]
    private var verticalReadyWaiters: [Int: [VerticalPageReadyWaiter]] = [:]
    private var provisionalVerticalNavigations: [UUID: Int] = [:]
    private var provisionalOnlyPageIndices: Set<Int> = []
    private var unavailableVerticalPageIndices: Set<Int> = []
    private var initialVerticalNavigationTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isUpdatingVerticalLayout = false
    private var isViewportUpdateScheduled = false

    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    /// Loaded page views in reading order.
    var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)

        if axis == .horizontalPaged, readingProgression == .rtl {
            orderedViews.reverse()
        }

        return orderedViews
    }

    private let scrollView = UIScrollView()

    var contentSize: CGSize {
        scrollView.contentSize
    }

    /// Insets applied to the outer continuous viewport.
    var contentInset: UIEdgeInsets {
        get { scrollView.contentInset }
        set {
            guard scrollView.contentInset != newValue else { return }
            updateVerticalLayout(updatingCurrentIndex: true) {
                scrollView.contentInset = newValue
            }
        }
    }

    func frameForView(at index: Int) -> CGRect? {
        guard let view = loadedViews[index] else {
            return nil
        }

        if axis == .verticalContinuous {
            guard verticalReadyRange?.contains(index) == true else {
                return nil
            }
        }
        return view.frame
    }

    func visibleFrame(at index: Int) -> CGRect? {
        guard let frame = frameForView(at: index) else {
            return nil
        }

        let intersection = effectiveViewport.intersection(frame)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        return intersection.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    var visibleIndices: [Int] {
        loadedViews.keys.sorted().filter { visibleFrame(at: $0) != nil }
    }

    /// Set while a transition animation is in progress to prevent
    /// `layoutSubviews` from resetting `contentOffset` and interrupting the
    /// animation.
    private var isAnimatingContentOffset = false

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
    }

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool,
        axis: Axis = .horizontalPaged
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled
        self.axis = axis

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = axis == .horizontalPaged
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        addSubview(scrollView)

        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        insertSubview(UIView(frame: .zero), at: 0)
        // Prevents the content from jumping down when the status bar is toggled
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        if axis == .verticalContinuous {
            layoutVerticalPages()
            return
        }

        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size
        scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)

        for (index, view) in loadedViews {
            view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y: 0), size: size)
        }

        if !isAnimatingContentOffset {
            scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
        }
    }

    func setVerticalPageHeight(_ height: CGFloat, isReady: Bool, at index: Int) {
        guard
            axis == .verticalContinuous,
            0 ..< pageCount ~= index,
            loadedViews[index] != nil
        else {
            return
        }

        let previousState = verticalPageStates[index]
        let resolvedHeight = max(0, height)
        updateVerticalLayout(
            transformingAnchor: { anchor in
                guard
                    anchor.index == index,
                    previousState?.isReady == true,
                    let previousHeight = previousState?.height,
                    previousHeight > 0
                else {
                    return anchor
                }
                return ViewportAnchor(
                    index: anchor.index,
                    localY: anchor.localY * resolvedHeight / previousHeight
                )
            },
            updatingCurrentIndex: previousState?.isReady == true
        ) {
            let wasReady = previousState?.isReady == true
            verticalPageStates[index] = VerticalPageState(
                height: resolvedHeight,
                isReady: isReady || wasReady
            )
        }

        if isReady, loadedViews[index] != nil {
            completeVerticalReadyWaiters(at: index, with: .ready)
        }
    }

    func setVerticalPageFailed(at index: Int) {
        guard axis == .verticalContinuous, 0 ..< pageCount ~= index else {
            return
        }

        unavailableVerticalPageIndices.insert(index)
        updateVerticalLayout {
            loadedViews.removeValue(forKey: index)?.removeFromSuperview()
            verticalPageStates.removeValue(forKey: index)
            loadingIndexQueue.removeAll { $0.index == index }
        }
        completeVerticalReadyWaiters(at: index, with: .unavailable)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            initialVerticalNavigationTask?.cancel()
            initialVerticalNavigationTask = nil
            cancelPageLoading(clearQueue: true)
            completeAllVerticalReadyWaiters(with: .unavailable)
            provisionalVerticalNavigations.removeAll()
            provisionalOnlyPageIndices.removeAll()

            // Remove all spread views to break retain cycles
            for (_, view) in loadedViews {
                view.removeFromSuperview()
            }
            loadedViews.removeAll()
            verticalPageStates.removeAll()
            unavailableVerticalPageIndices.removeAll()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            cancelPageLoading(clearQueue: false)
        } else {
            loadPages()
        }
    }

    private var effectiveViewport: CGRect {
        let inset = scrollView.adjustedContentInset
        return CGRect(
            x: scrollView.contentOffset.x + inset.left,
            y: scrollView.contentOffset.y + inset.top,
            width: max(0, scrollView.bounds.width - inset.left - inset.right),
            height: max(0, scrollView.bounds.height - inset.top - inset.bottom)
        )
    }

    private var verticalReadyRange: ClosedRange<Int>? {
        guard
            loadedViews[currentIndex] != nil,
            verticalPageStates[currentIndex]?.isReady == true
        else {
            return nil
        }

        var firstIndex = currentIndex
        while
            firstIndex > 0,
            loadedViews[firstIndex - 1] != nil,
            verticalPageStates[firstIndex - 1]?.isReady == true
        {
            firstIndex -= 1
        }

        var lastIndex = currentIndex
        while
            lastIndex + 1 < pageCount,
            loadedViews[lastIndex + 1] != nil,
            verticalPageStates[lastIndex + 1]?.isReady == true
        {
            lastIndex += 1
        }
        return firstIndex ... lastIndex
    }

    private func layoutVerticalPages() {
        let size = scrollView.bounds.size
        let readyRange = verticalReadyRange
        var y: CGFloat = 0

        for (index, view) in loadedViews.sorted(by: { $0.key < $1.key }) {
            guard
                readyRange?.contains(index) == true,
                let state = verticalPageStates[index]
            else {
                view.isHidden = true
                view.frame = CGRect(origin: .zero, size: size)
                continue
            }

            view.isHidden = false
            view.frame = CGRect(x: 0, y: y, width: size.width, height: state.height)
            y += state.height
        }

        scrollView.contentSize = CGSize(width: size.width, height: y)
        clampVerticalContentOffset()
    }

    private func updateVerticalLayout(
        transformingAnchor transformAnchor: ((ViewportAnchor) -> ViewportAnchor)? = nil,
        updatingCurrentIndex: Bool = false,
        _ updates: () -> Void
    ) {
        guard axis == .verticalContinuous else {
            updates()
            return
        }

        var anchor = viewportAnchor()
        isUpdatingVerticalLayout = true
        updates()
        if let transformAnchor, let currentAnchor = anchor {
            anchor = transformAnchor(currentAnchor)
        }
        layoutVerticalPages()
        restoreViewportAnchor(anchor)
        isUpdatingVerticalLayout = false
        if updatingCurrentIndex {
            updateCurrentIndexFromVerticalViewport()
        }
        scheduleViewportUpdate()
    }

    private func viewportAnchor() -> ViewportAnchor? {
        guard let index = visibleIndices.first, let frame = frameForView(at: index) else {
            return nil
        }
        return ViewportAnchor(index: index, localY: effectiveViewport.minY - frame.minY)
    }

    private func restoreViewportAnchor(_ anchor: ViewportAnchor?) {
        guard let anchor, let frame = frameForView(at: anchor.index) else {
            clampVerticalContentOffset()
            return
        }

        scrollView.contentOffset.y = frame.minY + anchor.localY - scrollView.adjustedContentInset.top
        clampVerticalContentOffset()
    }

    private func clampVerticalContentOffset() {
        let inset = scrollView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        scrollView.contentOffset.y = min(maximumY, max(minimumY, scrollView.contentOffset.y))
    }

    private func scheduleViewportUpdate() {
        guard !isViewportUpdateScheduled else {
            return
        }

        isViewportUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isViewportUpdateScheduled = false
            self.delegate?.paginationViewDidUpdateViewport(self)
        }
    }

    private func updateCurrentIndexFromVerticalViewport() {
        guard
            axis == .verticalContinuous,
            provisionalVerticalNavigations.isEmpty
        else {
            return
        }

        let viewportCenterY = effectiveViewport.midY
        let visibleIndices = visibleIndices
        let centerIndex = visibleIndices.first { index in
            guard let frame = frameForView(at: index) else { return false }
            return viewportCenterY >= frame.minY && viewportCenterY < frame.maxY
        }
        let nearestIndex = visibleIndices.min(by: { lhs, rhs in
            let lhsFrame = frameForView(at: lhs) ?? .zero
            let rhsFrame = frameForView(at: rhs) ?? .zero
            return abs(lhsFrame.midY - viewportCenterY) < abs(rhsFrame.midY - viewportCenterY)
        })
        if let index = centerIndex ?? nearestIndex {
            setCurrentIndex(index)
        }
    }

    /// Returns the x offset to the page view with given index in the scroll view.
    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }

    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        cancelPageLoading(clearQueue: true)
        initialVerticalNavigationTask?.cancel()
        initialVerticalNavigationTask = nil
        completeAllVerticalReadyWaiters(with: .unavailable)
        provisionalVerticalNavigations.removeAll()
        provisionalOnlyPageIndices.removeAll()

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        verticalPageStates.removeAll()
        unavailableVerticalPageIndices.removeAll()

        if axis == .verticalContinuous {
            let inset = scrollView.adjustedContentInset
            scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
            scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: 0)
        }

        if axis == .verticalContinuous {
            setCurrentIndex(index)
            initialVerticalNavigationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await navigateVertically(
                    at: index,
                    location: location,
                    animated: false
                )
            }
        } else {
            setCurrentIndex(index, location: location)
        }
    }

    /// Updates the current and pre-loaded views.
    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) {
        guard isEmpty || index != currentIndex else {
            return
        }

        // If no explicit location is given, we'll load either the beginning or the end of the
        // resource depending on the last index. This allows to navigate backward across resources,
        // starting from the end of each previous resource.
        let movingBackward = (currentIndex - 1 == index)
        let location = location ?? (movingBackward ? .end : .start)

        updateVerticalLayout {
            currentIndex = index

            if axis == .verticalContinuous {
                loadingIndexQueue.removeAll()
            }

            // To make sure that the views the most likely to be visible are loaded first, we first load
            // the current one, then the next ones and to finish the previous ones.
            scheduleLoadPage(at: index, location: location)
            let nextPositionCount = axis == .verticalContinuous
                ? max(1, preloadNextPositionCount)
                : preloadNextPositionCount
            let previousPositionCount = axis == .verticalContinuous
                ? max(1, preloadPreviousPositionCount)
                : preloadPreviousPositionCount
            let lastIndex = scheduleLoadPages(from: index, upToPositionCount: nextPositionCount, direction: .forward, location: .start)
            let firstIndex = scheduleLoadPages(from: index, upToPositionCount: previousPositionCount, direction: .backward, location: .end)

            for (i, view) in loadedViews {
                // Flushes the views that are not needed anymore.
                guard firstIndex ... lastIndex ~= i else {
                    completeVerticalReadyWaiters(at: i, with: .unavailable)
                    view.removeFromSuperview()
                    loadedViews.removeValue(forKey: i)
                    verticalPageStates.removeValue(forKey: i)
                    unavailableVerticalPageIndices.remove(i)
                    continue
                }
            }
        }

        loadPages()
    }

    private func loadPages() {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadPagesTask?.cancel()
        loadPagesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadNextPage(generation: generation)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func cancelPageLoading(clearQueue: Bool) {
        loadGeneration &+= 1
        loadPagesTask?.cancel()
        loadPagesTask = nil
        if clearQueue {
            loadingIndexQueue.removeAll()
        }
    }

    private func loadNextPage(generation: Int) async {
        guard !Task.isCancelled, generation == loadGeneration else {
            return
        }
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            return
        }

        if
            loadedViews[index] == nil,
            let view = delegate?.paginationView(self, pageViewAtIndex: index)
        {
            updateVerticalLayout {
                unavailableVerticalPageIndices.remove(index)
                loadedViews[index] = view
                scrollView.addSubview(view)
            }
            if axis == .horizontalPaged {
                setNeedsLayout()
            }
        }

        guard let view = loadedViews[index] else {
            unavailableVerticalPageIndices.insert(index)
            completeVerticalReadyWaiters(at: index, with: .unavailable)
            await loadNextPage(generation: generation)
            return
        }

        if axis == .horizontalPaged {
            await view.go(to: location, animated: false)
        }
        guard !Task.isCancelled, generation == loadGeneration else {
            return
        }
        await loadNextPage(generation: generation)
    }

    /// Queue views to be loaded until reaching the given number of pre-loaded positions.
    ///
    /// - Parameters:
    ///   - positionCount: Number of positions to pre-load before stopping.
    ///   - sourceIndex: Starting page index from which to pre-load the views.
    ///   - direction: The direction in which to load the views from the sourceIndex.
    /// - Returns: The last page index to be loaded after reaching the requested number of positions.
    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        let positionCost = axis == .verticalContinuous
            ? max(1, indexPositionCount)
            : indexPositionCount

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - positionCost,
            direction: direction,
            location: location
        )
    }

    /// Queue a page to be loaded at the given index, if it's not already loaded.
    ///
    /// - Returns: Whether page is or will be loaded.
    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        loadingIndexQueue.removeAll { $0.index == index }
        unavailableVerticalPageIndices.remove(index)
        loadingIndexQueue.append((index: index, location: location))
        return true
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Navigation

    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: Whether the move is possible.
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        let shouldAnimate = options.animated && !UIAccessibility.isReduceMotionEnabled

        if axis == .verticalContinuous {
            initialVerticalNavigationTask?.cancel()
            initialVerticalNavigationTask = nil
            return await navigateVertically(
                at: index,
                location: location,
                animated: shouldAnimate
            )
        }

        if currentIndex == index {
            await scrollToView(at: index, location: location, animated: shouldAnimate)
        } else if abs(currentIndex - index) == 1 {
            await slideToView(at: index, location: location, animated: shouldAnimate)
        } else {
            await fadeToView(at: index, location: location, animated: shouldAnimate)
        }
        return true
    }

    /// Loads a vertical navigation target without changing the visible
    /// resource. The target becomes current only after it is ready.
    private func prepareVerticalPage(
        at index: Int,
        location: PageLocation
    ) async -> Bool {
        if verticalPageStates[index]?.isReady == true, loadedViews[index] != nil {
            return true
        }

        guard scheduleLoadPage(at: index, location: location) else {
            return false
        }
        loadPages()

        return await waitUntilVerticalPageIsReady(at: index) == .ready
            && !Task.isCancelled
    }

    private func navigateVertically(
        at index: Int,
        location: PageLocation,
        animated: Bool
    ) async -> Bool {
        let navigationID = UUID()
        let isProvisional = index != currentIndex
        if isProvisional, loadedViews[index] == nil {
            provisionalOnlyPageIndices.insert(index)
        }
        if isProvisional {
            provisionalVerticalNavigations[navigationID] = index
        }
        var didCommit = false
        defer {
            if isProvisional {
                provisionalVerticalNavigations.removeValue(forKey: navigationID)
                if didCommit {
                    provisionalOnlyPageIndices.remove(index)
                } else if
                    !provisionalVerticalNavigations.values.contains(index),
                    provisionalOnlyPageIndices.remove(index) != nil
                {
                    discardProvisionalVerticalPage(at: index)
                }
            }
        }

        guard
            await prepareVerticalPage(at: index, location: location),
            !Task.isCancelled,
            let targetView = loadedViews[index],
            verticalPageStates[index]?.isReady == true
        else {
            return false
        }

        let localY: CGFloat?
        do {
            localY = try await delegate?.paginationView(
                self,
                verticalOffsetFor: location,
                at: index
            )
        } catch {
            return false
        }
        guard
            !Task.isCancelled,
            let localY,
            localY.isFinite,
            localY >= 0,
            loadedViews[index] === targetView,
            verticalPageStates[index]?.isReady == true
        else {
            return false
        }

        if currentIndex != index {
            setCurrentIndex(index)
        }
        guard
            loadedViews[index] === targetView,
            let frame = frameForView(at: index)
        else {
            return false
        }

        let maximumLocalY = max(0, frame.height - effectiveViewport.height)
        let alignedLocalY = min(localY, maximumLocalY)
        let targetY = frame.minY + alignedLocalY - scrollView.adjustedContentInset.top
        let updateOffset = {
            self.scrollView.contentOffset.y = targetY
            self.clampVerticalContentOffset()
        }
        didCommit = true

        if animated {
            await animate(duration: 0.3, animations: updateOffset)
        } else {
            updateOffset()
        }
        scheduleViewportUpdate()
        return true
    }

    private func discardProvisionalVerticalPage(at index: Int) {
        guard index != currentIndex else { return }

        updateVerticalLayout {
            loadedViews.removeValue(forKey: index)?.removeFromSuperview()
            verticalPageStates.removeValue(forKey: index)
            unavailableVerticalPageIndices.remove(index)
            loadingIndexQueue.removeAll { $0.index == index }
        }
        completeVerticalReadyWaiters(at: index, with: .unavailable)
    }

    private func waitUntilVerticalPageIsReady(at index: Int) async -> VerticalPageReadyResult {
        if verticalPageStates[index]?.isReady == true, loadedViews[index] != nil {
            return .ready
        }
        if unavailableVerticalPageIndices.contains(index) {
            return .unavailable
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                verticalReadyWaiters[index, default: []].append(
                    VerticalPageReadyWaiter(id: id, continuation: continuation)
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.completeVerticalReadyWaiter(
                    at: index,
                    id: id,
                    with: .unavailable
                )
            }
        }
    }

    private func completeVerticalReadyWaiter(
        at index: Int,
        id: UUID,
        with result: VerticalPageReadyResult
    ) {
        guard
            var waiters = verticalReadyWaiters[index],
            let waiterIndex = waiters.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let waiter = waiters.remove(at: waiterIndex)
        if waiters.isEmpty {
            verticalReadyWaiters.removeValue(forKey: index)
        } else {
            verticalReadyWaiters[index] = waiters
        }
        waiter.continuation.resume(returning: result)
    }

    private func completeVerticalReadyWaiters(
        at index: Int,
        with result: VerticalPageReadyResult
    ) {
        let waiters = verticalReadyWaiters.removeValue(forKey: index) ?? []
        waiters.forEach { $0.continuation.resume(returning: result) }
    }

    private func completeAllVerticalReadyWaiters(with result: VerticalPageReadyResult) {
        let waiters = verticalReadyWaiters.values.flatMap { $0 }
        verticalReadyWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: result) }
    }

    private func slideToView(at index: Int, location: PageLocation, animated: Bool) async {
        let fromOffset = scrollView.contentOffset
        let targetOffset = CGPoint(x: xOffsetForIndex(index), y: fromOffset.y)
        let translationX = fromOffset.x - targetOffset.x

        // We use a snapshot of the current view for two reasons:
        //
        // 1. The current view might get flushed when calling
        //    `setCurrentIndex()`, but we want to keep it on the screen during
        //    the animation.
        // 2. A workaround for visual glitches, see https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        let snapshot = snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = bounds
            addSubview(snapshot)
        } else {
            log(.warning, "Could not take a snapshot before sliding to view at index \(index); page transition may flash")
        }

        isAnimatingContentOffset = true
        scrollView.isScrollEnabled = false

        defer {
            snapshot?.removeFromSuperview()
            isAnimatingContentOffset = false
            scrollView.isScrollEnabled = isScrollEnabled
        }

        setCurrentIndex(index, location: location)

        scrollView.contentOffset = fromOffset

        if animated {
            await animate(duration: 0.3) {
                snapshot?.transform = CGAffineTransform(translationX: translationX, y: 0)
                self.scrollView.contentOffset = targetOffset
            }
        } else {
            scrollView.contentOffset = targetOffset
        }

        // There are visual glitches when scrolling web views into view.
        // To prevent these, we wait a few ms before removing the snapshot.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        if !animated {
            try? await Task.sleep(seconds: 0.1)
        }
    }

    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
        func fade(to alpha: CGFloat) async {
            await animate(duration: animated ? 0.15 : 0) {
                self.alpha = alpha
            }
        }

        await fade(to: 0)
        await scrollToView(at: index, location: location, animated: false)
        await fade(to: 1)
    }

    private func scrollToView(at index: Int, location: PageLocation, animated: Bool) async {
        guard currentIndex != index else {
            if let view = currentView {
                await view.go(to: location, animated: animated)
            }
            return
        }

        scrollView.isScrollEnabled = isScrollEnabled
        setCurrentIndex(index, location: location)

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: xOffsetForIndex(index),
                y: scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: animated)
    }

    private func animate(duration: TimeInterval, animations: @escaping () -> Void) async {
        if duration > 0 {
            await withCheckedContinuation { continuation in
                UIView.animate(
                    withDuration: duration,
                    animations: animations,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        } else {
            animations()
        }
    }
}

extension PaginationView: UIScrollViewDelegate {
    // We disable the scroll once the user releases the drag to prevent scrolling through more than 1 resource at a
    // time. Otherwise, because the pagination view's scroll view would have the focus during the scroll gesture, the
    // scrollable content of the resources would be skipped.
    // Note: using this approach might provide a better experience:
    // https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard axis == .horizontalPaged else { return }
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = isScrollEnabled
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard axis == .horizontalPaged else { return }

        // A programmatic slide animation sets isScrollEnabled = false and drives the
        // content offset directly. If a delegate callback fires during or just after
        // that window it could call setCurrentIndex with a stale offset, so we bail out.
        guard !isAnimatingContentOffset else { return }

        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        setCurrentIndex(newIndex)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard axis == .verticalContinuous, !isUpdatingVerticalLayout else {
            return
        }

        scheduleViewportUpdate()
        updateCurrentIndexFromVerticalViewport()
    }
}
