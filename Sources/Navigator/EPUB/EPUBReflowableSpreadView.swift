//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var pageTurnPanEnabledObservation: NSKeyValueObservation?

    var contentHeightDidChange: ((CGFloat) -> Void)?

    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private(set) var contentHeight: CGFloat?

    private var usesContinuousOuterScroll: Bool {
        viewModel.scroll && !viewModel.verticalText
    }

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
        super.clear()

        // Clean up go to continuations.
        for waiter in goToWaiters {
            waiter.resume(returning: false)
        }
        goToWaiters.removeAll()
        pendingLocation = nil

        finishLegacyScrollAnimation()
        if let wait = pendingOperationScrollAnimation {
            finishScrollAnimationWait(wait, with: .cancelled, poison: false)
        }
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = !viewModel.scroll
        updateContinuousScrolling()

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        // Disables paginated mode if scroll is on.
        scrollView.isPagingEnabled = !viewModel.scroll
        updateContinuousScrolling()

        updateContentInset()
    }

    private func updateContentInset() {
        let contentInset = delegate?.spreadViewContentInset(self) ?? .zero

        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInset

        } else {
            topConstraint.constant = contentInset.top
            bottomConstraint.constant = -contentInset.bottom
            scrollView.contentInset = .zero
        }
    }

    private func updateContinuousScrolling() {
        let isContinuous = viewModel.scroll && !viewModel.verticalText
        scrollView.isScrollEnabled = !isContinuous
        updateNativeHorizontalPaging()
        if isContinuous {
            scrollView.contentOffset = .zero
        }
    }

    override func updateNativeHorizontalPaging() {
        if !allowsNativeHorizontalPaging {
            installNativeHorizontalPanGuard()
            scrollView.panGestureRecognizer.isEnabled = false
            return
        }
        pageTurnPanEnabledObservation = nil
        scrollView.panGestureRecognizer.isEnabled = !usesContinuousOuterScroll
    }

    private func installNativeHorizontalPanGuard() {
        guard pageTurnPanEnabledObservation == nil else { return }
        pageTurnPanEnabledObservation = scrollView.panGestureRecognizer.observe(
            \.isEnabled,
            options: [.new]
        ) { [weak self] recognizer, change in
            guard
                self?.allowsNativeHorizontalPaging == false,
                change.newValue == true
            else {
                return
            }
            recognizer.isEnabled = false
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    /// Leading-edge progression for a horizontal resource, matching the JS
    /// definition in `Scripts/src/utils.js` (`abs(scrollX) / scrollWidth`).
    ///
    /// Prefer this (or `leadingProgression`) over ad-hoc
    /// `contentOffset / (contentSize - bounds)` math — that overestimates
    /// non-zero positions and breaks cancel-restore validation.
    static func leadingProgression(
        contentOffsetX: CGFloat,
        contentWidth: CGFloat
    ) -> Double {
        guard contentWidth > 0 else { return 0 }
        return min(max(Double(abs(contentOffsetX) / contentWidth), 0), 1)
    }

    /// Mirrors `Scripts/src/utils.js` `snapOffset` for LTR/RTL page columns.
    static func snapOffset(
        _ offset: CGFloat,
        pageWidth: CGFloat,
        isRTL: Bool
    ) -> CGFloat {
        guard pageWidth > 0 else { return offset }
        let delta: CGFloat = isRTL ? -1 : 1
        let value = offset + delta
        return value - value.truncatingRemainder(dividingBy: pageWidth)
    }

    static let settlementPixelTolerance: CGFloat = 1

    /// Converts a requested progression to the leading-edge value JS
    /// `scrollToPosition` can actually reach.
    ///
    /// Paginated resources snap to a page then clamp to the browser max
    /// scroll (`contentWidth - pageWidth`). Vertical-text scroll mode does
    /// not snap: JS uses `-scrollWidth * progression`.
    static func reachableHorizontalProgression(
        requested: Double,
        pageWidth: CGFloat,
        contentWidth: CGFloat,
        isRTL: Bool = false,
        snapsToPage: Bool = true
    ) -> Double {
        guard pageWidth > 0, contentWidth > 0 else { return 0 }
        let clampedRequest = min(max(requested, 0), 1)
        let maxAbsOffset = max(contentWidth - pageWidth, 0)
        if !snapsToPage {
            let rawOffset = -contentWidth * CGFloat(clampedRequest)
            let clampedOffset = min(max(rawOffset, -maxAbsOffset), 0)
            return leadingProgression(
                contentOffsetX: clampedOffset,
                contentWidth: contentWidth
            )
        }
        let factor: CGFloat = isRTL ? -1 : 1
        let rawOffset = contentWidth * CGFloat(clampedRequest) * factor
        let snapped = snapOffset(rawOffset, pageWidth: pageWidth, isRTL: isRTL)
        let clampedOffset = isRTL
            ? min(max(snapped, -maxAbsOffset), 0)
            : min(max(snapped, 0), maxAbsOffset)
        return leadingProgression(
            contentOffsetX: clampedOffset,
            contentWidth: contentWidth
        )
    }

    static func isAtHorizontalProgression(
        live: Double,
        requested: Double,
        pageWidth: CGFloat,
        contentWidth: CGFloat,
        isRTL: Bool = false,
        snapsToPage: Bool = true
    ) -> Bool {
        guard pageWidth > 0, contentWidth > 0 else { return false }
        let reachable = reachableHorizontalProgression(
            requested: requested,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            isRTL: isRTL,
            snapsToPage: snapsToPage
        )
        let pixelTolerance = Double(settlementPixelTolerance / contentWidth)
        return abs(live - reachable) <= max(pixelTolerance, 0.000_001)
    }

    static func clampScrollOffsetX(
        _ offset: CGFloat,
        pageWidth: CGFloat,
        contentWidth: CGFloat,
        isRTL: Bool
    ) -> CGFloat {
        let maxAbs = max(contentWidth - pageWidth, 0)
        return isRTL
            ? min(max(offset, -maxAbs), 0)
            : min(max(offset, 0), maxAbs)
    }

    static func clampScrollOffsetY(
        _ offset: CGFloat,
        pageHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        min(max(offset, 0), max(contentHeight - pageHeight, 0))
    }

    /// Target X matching `documentScrollTargetForRect`: snap when paginated,
    /// then clamp to the browser-reachable scroll range.
    static func locatorTargetOffsetX(
        rectLeft: CGFloat,
        scrollX: CGFloat,
        pageWidth: CGFloat,
        contentWidth: CGFloat = .greatestFiniteMagnitude,
        isRTL: Bool = false,
        snapsToPage: Bool = true
    ) -> CGFloat {
        let raw = rectLeft + scrollX
        let prepared = snapsToPage
            ? snapOffset(raw, pageWidth: pageWidth, isRTL: isRTL)
            : raw
        return clampScrollOffsetX(
            prepared,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            isRTL: isRTL
        )
    }

    static func locatorIsAtScrollTarget(
        currentOffset: CGFloat,
        targetOffset: CGFloat,
        pixelTolerance: CGFloat = settlementPixelTolerance
    ) -> Bool {
        abs(currentOffset - targetOffset) <= pixelTolerance
    }

    static func javaScriptStringLiteral(_ value: String) -> String? {
        guard
            let data = try? JSONEncoder().encode(value),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return encoded
    }

    enum ReflowableNavigationTarget: Equatable {
        case locator
        case fragment(String)
        case progression(Double)
        case unresolvedPosition
    }

    static func reflowableNavigationTarget(
        for locator: Locator
    ) -> ReflowableNavigationTarget {
        if locator.text.highlight != nil || locator.locations.cssSelector != nil {
            return .locator
        }
        if let id = locator.locations.fragments.first, !id.isEmpty {
            return .fragment(id)
        }
        if let progression = locator.locations.progression {
            return .progression(progression)
        }
        if locator.locations.position != nil {
            return .unresolvedPosition
        }
        return .progression(0)
    }

    /// Live leading progression for the current viewport from scroll geometry.
    ///
    /// Always derived from the scroll view with the JS formula so callers can
    /// validate immediately after programmatic `go` without waiting on a
    /// `progressionChanged` message (which can lag or be suppressed).
    var leadingProgression: Double {
        Self.leadingProgression(
            contentOffsetX: scrollView.contentOffset.x,
            contentWidth: scrollView.contentSize.width
        )
    }

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func spreadDidLoad() async {
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            await evaluateScript("readium.link = \(linkJSON);")
        }

        // TODO: Better solution for delaying scrolling to pending location
        // This delay is used to wait for the web view pagination to settle and give the CSS and webview time to layout
        // correctly before attempting to scroll to the target progression, otherwise we might end up at the wrong spot.
        // 0.2 seconds seems like a good value for it to work on an iPhone 5s.
        try? await Task.sleep(seconds: 0.2)

        if usesContinuousOuterScroll {
            await updateContentHeight(evaluateScript("readium.documentHeight()"))
            scrollView.contentOffset = .zero
            didCompleteGoTo()
        } else {
            guard let location = pendingLocation else {
                return
            }
            _ = await go(
                to: location.location,
                animated: location.animated,
                waitForLoad: true
            )
            if pendingLocation?.id == location.id {
                pendingLocation = nil
            }

            // The rendering is sometimes very slow. So in case we don't show the first page of the resource, we add
            // a generous delay before showing the spread again.
            let delayed = !location.location.isStart
            try? await Task.sleep(seconds: delayed ? 0.3 : 0)
        }
    }

    /// Resolves a page location to a resource-local document Y coordinate.
    func resolveVerticalOffset(for location: PageLocation) async -> CGFloat? {
        await spreadLoaded()

        switch location {
        case .start:
            return 0
        case .end:
            return contentHeight
        case let .locator(locator):
            return await resolveVerticalOffset(for: locator)
        }
    }

    /// Resolves the given Locator to a resource-local document Y coordinate.
    func resolveVerticalOffset(for locator: Locator) async -> CGFloat? {
        guard let json = try? locator.jsonString() else {
            return nil
        }

        let result = await evaluateScript("readium.resolveVerticalOffset(\(json))")
        guard
            case let .success(value) = result,
            let number = value as? NSNumber
        else {
            return nil
        }

        let offset = CGFloat(number.doubleValue)
        return offset.isFinite && offset >= 0 ? offset : nil
    }

    /// Returns the visible progression range for a resource-local document rect.
    func progression(in visibleFrame: CGRect) -> ClosedRange<Double> {
        guard
            let contentHeight,
            contentHeight > 0,
            visibleFrame.minY.isFinite,
            visibleFrame.maxY.isFinite
        else {
            return 0 ... 0
        }

        let first = min(max(Double(visibleFrame.minY / contentHeight), 0), 1)
        let last = min(max(Double(visibleFrame.maxY / contentHeight), first), 1)
        return first ... last
    }

    /// Finds the first element intersecting a resource-local document rect.
    func findFirstVisibleElementLocator(in rect: CGRect) async -> Locator? {
        guard
            rect.origin.x.isFinite,
            rect.origin.y.isFinite,
            rect.width.isFinite,
            rect.height.isFinite,
            let rectJSON = try? JSONValue.object([
                "x": .double(Double(rect.origin.x)),
                "y": .double(Double(rect.origin.y)),
                "width": .double(Double(rect.width)),
                "height": .double(Double(rect.height)),
            ]).jsonString()
        else {
            return nil
        }

        let result = await evaluateScript("readium.findFirstVisibleLocatorInRect(\(rectJSON))")
        do {
            guard
                let json = try JSONValue(result.get()),
                let locator = try Locator(json: json)
            else {
                return nil
            }
            let link = spread.first.link
            return locator.copy(href: link.url(), mediaType: link.mediaType ?? .xhtml)
        } catch {
            log(.error, error)
            return nil
        }
    }

    /// Sets the resource-local document viewport used by continuous layout.
    func setContinuousViewport(_ rect: CGRect?) async {
        guard isSpreadLoaded, !Task.isCancelled else {
            return
        }

        let rectJSON: String
        if let rect {
            guard
                rect.origin.x.isFinite,
                rect.origin.y.isFinite,
                rect.width.isFinite,
                rect.height.isFinite,
                let json = try? JSONValue.object([
                    "x": .double(Double(rect.origin.x)),
                    "y": .double(Double(rect.origin.y)),
                    "width": .double(Double(rect.width)),
                    "height": .double(Double(rect.height)),
                ]).jsonString()
            else {
                return
            }
            rectJSON = json
            scrollView.isScrollEnabled = false
            scrollView.contentOffset = .zero
        } else {
            rectJSON = "null"
        }

        await evaluateScript("readium.setViewportRect(\(rectJSON))")
    }

    private func updateContentHeight(_ result: Result<Any, Error>) {
        guard case let .success(value) = result else {
            return
        }
        updateContentHeight(value)
    }

    private func updateContentHeight(_ value: Any) {
        guard let number = value as? NSNumber else {
            return
        }
        let height = CGFloat(number.doubleValue)
        guard height.isFinite, height > 0, height != contentHeight else {
            return
        }

        contentHeight = height
        contentHeightDidChange?(height)
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        let factor: CGFloat = {
            switch direction {
            case .left:
                return -1
            case .right:
                return 1
            }
        }()

        guard scrollView.bounds.width > 0 else { return false }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return false
        }

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let behavior = Self.pageTurnScrollBehavior(options: options)
        await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });")

        if options.animated {
            // Waits for the scroll animation to finish.
            await withCheckedContinuation { continuation in
                let request = ScrollAnimationRequest(continuation)
                pendingScrollAnimation?.resume()
                pendingScrollAnimation = request

                // Safety net in case no native scroll-end callback fires. The identity
                // check on `request` ensures a stale timeout from a previous
                // request does not resume a newer one.
                Task { @MainActor in
                    try? await Task.sleep(seconds: 0.8)
                    finishLegacyScrollAnimation(for: request)
                }
            }
        }

        return true
    }

    override func go(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        guard !viewModel.scroll else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        if let result = operation.check(spreadGeneration: spreadGeneration) {
            return .rejected(
                result,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        let factor: CGFloat = direction == .left ? -1 : 1
        guard scrollView.bounds.width > 0 else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stage: .preflight
            )
        }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return .rejected(
                .spreadNotLoaded,
                mayHaveMutated: false,
                stage: .preflight
            )
        }

        let behavior = Self.pageTurnScrollBehavior(options: options)
        let animationWait = options.animated
            ? beginScrollAnimationWait(
                operation: operation,
                targetReached: { [weak self] in
                    guard let self else { return false }
                    return abs(self.scrollView.contentOffset.x - targetX) <= 0.5
                }
            )
            : nil
        let evaluation = await evaluateScript(
            "window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });",
            operation: operation,
            effect: .positionMutation
        )
        guard evaluation.result.isApplied else {
            if let animationWait {
                finishScrollAnimationWait(
                    animationWait,
                    with: evaluation.result,
                    poison: false
                )
            }
            return .rejected(
                evaluation.result,
                mayHaveMutated: true,
                stage: .pageViewMutation
            )
        }
        if let animationWait {
            startScrollAnimationStabilityCheck(animationWait)
            let animationResult = await waitForScrollAnimation(animationWait)
            guard animationResult.isApplied else {
                return .rejected(
                    animationResult,
                    mayHaveMutated: true,
                    stage: .pageViewMutation
                )
            }
        }
        if let result = operation.check(spreadGeneration: spreadGeneration) {
            return .rejected(
                result,
                mayHaveMutated: true,
                stage: .pageViewMutation
            )
        }
        return .applied(mayHaveMutated: true)
    }

    struct ScrollAnimationSettlement {
        private static let movementTolerance: CGFloat = 0.25
        private static let quietWindow: UInt64 = 300_000_000

        private let initialOffset: CGPoint
        private var lastOffset: CGPoint
        private var lastMovement: UInt64
        private var didObserveMovement = false

        init(initialOffset: CGPoint, submittedAt: UInt64) {
            self.initialOffset = initialOffset
            lastOffset = initialOffset
            lastMovement = submittedAt
        }

        mutating func observe(
            offset: CGPoint,
            at now: UInt64,
            targetReached: Bool
        ) -> Bool {
            let movedSinceSubmission =
                abs(offset.x - initialOffset.x) > Self.movementTolerance
                    || abs(offset.y - initialOffset.y) > Self.movementTolerance
            let movedSinceLastObservation =
                abs(offset.x - lastOffset.x) > Self.movementTolerance
                    || abs(offset.y - lastOffset.y) > Self.movementTolerance
            if movedSinceSubmission {
                didObserveMovement = true
            }
            if movedSinceLastObservation {
                lastOffset = offset
                lastMovement = now
            }

            // A no-op navigation is complete only when live target geometry
            // proves the requested locator was already at the viewport.
            if !didObserveMovement {
                return targetReached
            }
            guard targetReached, now >= lastMovement else { return false }
            return now - lastMovement >= Self.quietWindow
        }
    }

    private final class ScrollAnimationWait {
        let waiter: ScrollAnimationResultWaiter
        let initialOffset: CGPoint
        let targetReached: @MainActor () async -> Bool
        var deadlineTask: Task<Void, Never>?
        var settleTask: Task<Void, Never>?

        init(
            waiter: ScrollAnimationResultWaiter,
            initialOffset: CGPoint,
            targetReached: @escaping @MainActor () async -> Bool
        ) {
            self.waiter = waiter
            self.initialOffset = initialOffset
            self.targetReached = targetReached
        }
    }

    private func beginScrollAnimationWait(
        operation: NavigationOperationToken,
        targetReached: @escaping @MainActor () async -> Bool
    ) -> ScrollAnimationWait {
        let waiter = ScrollAnimationResultWaiter()
        let wait = ScrollAnimationWait(
            waiter: waiter,
            initialOffset: scrollView.contentOffset,
            targetReached: targetReached
        )
        if let pending = pendingOperationScrollAnimation {
            finishScrollAnimationWait(pending, with: .superseded, poison: false)
        }
        pendingOperationScrollAnimation = wait
        let delay = operation.remainingNanoseconds
        wait.deadlineTask = Task { @MainActor [weak self, weak wait] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let wait else { return }
            self?.finishScrollAnimationWait(wait, with: .timedOut, poison: true)
        }
        return wait
    }

    private func startScrollAnimationStabilityCheck(
        _ wait: ScrollAnimationWait
    ) {
        guard pendingOperationScrollAnimation === wait else { return }
        wait.settleTask = Task { @MainActor [weak self, weak wait] in
            guard let self, let wait else { return }
            var settlement = ScrollAnimationSettlement(
                initialOffset: wait.initialOffset,
                submittedAt: DispatchTime.now().uptimeNanoseconds
            )
            var lastTargetVerification: UInt64?
            while !Task.isCancelled,
                  pendingOperationScrollAnimation === wait
            {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                let offset = scrollView.contentOffset
                let now = DispatchTime.now().uptimeNanoseconds
                // DOM locator verification evaluates JavaScript. Throttle it so
                // the observer cannot flood WebKit while smooth scrolling.
                let shouldVerifyTarget = lastTargetVerification.map {
                    now >= $0 && now - $0 >= 100_000_000
                } ?? true
                let targetReached: Bool
                if shouldVerifyTarget {
                    lastTargetVerification = now
                    targetReached = await wait.targetReached()
                } else {
                    targetReached = false
                }
                guard pendingOperationScrollAnimation === wait else { return }
                if settlement.observe(
                    offset: offset,
                    at: now,
                    targetReached: targetReached
                ) {
                    finishScrollAnimationWait(
                        wait,
                        with: .applied,
                        poison: false
                    )
                    return
                }
            }
        }
    }

    private func waitForScrollAnimation(
        _ wait: ScrollAnimationWait
    ) async -> NavigationResult {
        let result = await withTaskCancellationHandler {
            await wait.waiter.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishScrollAnimationWait(wait, with: .cancelled, poison: true)
            }
        }
        wait.deadlineTask?.cancel()
        wait.deadlineTask = nil
        wait.settleTask?.cancel()
        wait.settleTask = nil
        return result
    }

    private func finishScrollAnimationWait(
        _ wait: ScrollAnimationWait,
        with result: NavigationResult,
        poison shouldPoison: Bool
    ) {
        let didFinish = wait.waiter.finish(result)
        wait.deadlineTask?.cancel()
        wait.deadlineTask = nil
        wait.settleTask?.cancel()
        wait.settleTask = nil
        if pendingOperationScrollAnimation === wait {
            pendingOperationScrollAnimation = nil
        }
        if shouldPoison, didFinish {
            poison(with: result)
        }
    }

    override func adjacentPageTurnSnapshotOffset(to direction: Direction) -> CGPoint? {
        guard
            !viewModel.scroll,
            isSpreadLoaded,
            !isTerminated,
            scrollView.bounds.width > 0
        else {
            return nil
        }
        let delta: CGFloat
        switch direction {
        case .left:
            delta = -scrollView.bounds.width
        case .right:
            delta = scrollView.bounds.width
        }
        let maximumX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let targetX = scrollView.contentOffset.x + delta
        guard targetX >= -0.5, targetX <= maximumX + 0.5 else { return nil }
        return CGPoint(x: min(max(targetX, 0), maximumX), y: scrollView.contentOffset.y)
    }

    override func pageTurnSnapshotPageIndex(at offset: CGPoint) -> Int {
        guard scrollView.bounds.width > 0 else { return 0 }
        return Int(round(offset.x / scrollView.bounds.width))
    }

    /// Selection-handle drags and interrupted page-turns can leave the web
    /// scroll view mid-page (half previous / half next) while outer chrome
    /// stays full-width. Snap back to a whole column/page.
    override func snapToNearestHorizontalPage() {
        guard
            !viewModel.scroll,
            !isCapturingPageTurnSnapshot,
            isSpreadLoaded,
            !isTerminated
        else {
            return
        }
        let width = scrollView.bounds.width
        guard width > 0, width.isFinite else { return }
        let maximumX = max(0, scrollView.contentSize.width - width)
        let page = (scrollView.contentOffset.x / width).rounded()
        let targetX = min(max(0, page * width), maximumX)
        guard abs(scrollView.contentOffset.x - targetX) > 0.5 else { return }
        scrollView.setContentOffset(
            CGPoint(x: targetX, y: scrollView.contentOffset.y),
            animated: false
        )
    }

    static func pageTurnScrollBehavior(options: NavigatorGoOptions) -> String {
        options.animated ? "smooth" : "instant"
    }

    private struct PendingLocation {
        let id: UUID
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation? = .init(
        id: UUID(),
        location: .start,
        animated: false
    )

    override func go(
        to location: PageLocation,
        animated: Bool,
        waitForLoad: Bool
    ) async -> Bool {
        if usesContinuousOuterScroll {
            guard isSpreadLoaded else {
                guard waitForLoad else { return false }
                let pending = PendingLocation(
                    id: UUID(),
                    location: location,
                    animated: animated
                )
                pendingLocation = pending
                let completed = await waitGoToCompletion()
                if !completed, pendingLocation?.id == pending.id {
                    pendingLocation = nil
                }
                return completed
            }

            didCompleteGoTo()
            return true
        }

        guard isSpreadLoaded else {
            guard waitForLoad else { return false }
            // Delays moving to the location until the document is loaded.
            let pending = PendingLocation(
                id: UUID(),
                location: location,
                animated: animated
            )
            pendingLocation = pending

            let completed = await waitGoToCompletion()
            if !completed, pendingLocation?.id == pending.id {
                pendingLocation = nil
            }
            return completed
        }

        switch location {
        case let .locator(locator):
            await go(to: locator, animated: animated)
        case .start:
            await scroll(toProgression: 0, animated: animated)
        case .end:
            await scroll(toProgression: 1, animated: animated)
        }

        didCompleteGoTo()
        return true
    }

    override func go(
        to location: PageLocation,
        animated: Bool,
        waitForLoad: Bool,
        operation: NavigationOperationToken
    ) async -> NavigationMutationResult {
        if !isSpreadLoaded {
            guard waitForLoad else {
                return .init(
                    result: .spreadNotLoaded,
                    mayHaveMutated: false,
                    failureStage: .targetLoad
                )
            }
            let loadResult = await spreadLoaded(operation: operation)
            guard loadResult.isApplied else {
                return .init(
                    result: loadResult,
                    mayHaveMutated: false,
                    failureStage: .targetLoad
                )
            }
        }
        if let result = operation.check(spreadGeneration: spreadGeneration) {
            return .init(
                result: result,
                mayHaveMutated: false,
                failureStage: .preflight
            )
        }
        if usesContinuousOuterScroll {
            return .init(result: .applied, mayHaveMutated: false)
        }

        let result: NavigationResult
        switch location {
        case let .locator(locator):
            result = await go(to: locator, animated: animated, operation: operation)
        case .start:
            result = await scroll(toProgression: 0, animated: animated, operation: operation)
        case .end:
            result = await scroll(toProgression: 1, animated: animated, operation: operation)
        }
        return .init(
            result: result,
            mayHaveMutated: true,
            failureStage: result.isApplied ? nil : .pageViewMutation
        )
    }

    private func waitGoToCompletion() async -> Bool {
        guard !didReportNavigationFailure else {
            return false
        }
        let waiter = GoToWaiter()
        goToWaiters.append(waiter)
        return await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                waiter.resume(returning: false)
                self?.goToWaiters.removeAll { $0 === waiter }
            }
        }
    }

    private func didCompleteGoTo() {
        for waiter in goToWaiters {
            waiter.resume(returning: true)
        }
        goToWaiters.removeAll()
    }

    @MainActor
    private final class GoToWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
            }
        }

        func resume(returning result: Bool) {
            guard self.result == nil else { return }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: result)
        }
    }

    private var goToWaiters: [GoToWaiter] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?
    private var pendingOperationScrollAnimation: ScrollAnimationWait?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?
        private var completion: (() -> Void)?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
            completion?()
            completion = nil
        }
    }

    @MainActor
    private final class ScrollAnimationResultWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<NavigationResult, Never>?
        private var result: NavigationResult?

        func wait() async -> NavigationResult {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                }
            }
        }

        @discardableResult
        func finish(_ result: NavigationResult) -> Bool {
            guard self.result == nil else { return false }
            self.result = result
            continuation?.resume(returning: result)
            continuation = nil
            return true
        }
    }

    private func finishLegacyScrollAnimation(for request: ScrollAnimationRequest? = nil) {
        guard request == nil || pendingScrollAnimation === request else {
            return
        }
        pendingScrollAnimation?.resume()
        pendingScrollAnimation = nil
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        switch Self.reflowableNavigationTarget(for: locator) {
        case .locator:
            return await scroll(toLocator: locator, animated: animated)
        case let .fragment(id):
            return await scroll(toTagID: id, animated: animated)
        case let .progression(progression):
            return await scroll(toProgression: progression, animated: animated)
        case .unresolvedPosition:
            return false
        }
    }

    private func go(
        to locator: Locator,
        animated: Bool,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                return .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded)
            }
        }

        switch Self.reflowableNavigationTarget(for: locator) {
        case .locator:
            guard let json = try? locator.jsonString() else {
                return .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded)
            }
            return await evaluatePositionMutation(
                "readium.scrollToLocator(\(json), \(animated));",
                animated: animated,
                operation: operation,
                expectsBooleanSuccess: true,
                targetReached: { [weak self] in
                    guard let self else { return false }
                    return await self.isLocatorVisible(
                        locator,
                        operation: operation
                    ).isApplied
                }
            )
        case let .fragment(id):
            guard let idLiteral = Self.javaScriptStringLiteral(id) else {
                return .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded)
            }
            return await evaluatePositionMutation(
                "readium.scrollToId(\(idLiteral), \(animated));",
                animated: animated,
                operation: operation,
                expectsBooleanSuccess: true,
                targetReached: { [weak self] in
                    guard let self else { return false }
                    return await self.isLocatorVisible(
                        locator,
                        operation: operation
                    ).isApplied
                }
            )
        case let .progression(progression):
            return await scroll(
                toProgression: progression,
                animated: animated,
                operation: operation
            )
        case .unresolvedPosition:
            return .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded)
        }
    }

    private func scroll(
        toProgression progression: Double,
        animated: Bool,
        operation: NavigationOperationToken
    ) async -> NavigationResult {
        guard 0 ... 1 ~= progression else {
            return .failed(EPUBNavigatorViewController.EPUBError.spreadNotLoaded)
        }
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = progression == 0
                ? -scrollView.contentInset.top
                : scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.contentInset.bottom
            scrollView.contentOffset = contentOffset
            return operation.check(spreadGeneration: spreadGeneration) ?? .applied
        }
        let direction = viewModel.readingProgression.rawValue
        return await evaluatePositionMutation(
            "readium.scrollToPosition(\'\(progression)\', \'\(direction)\', \(animated))",
            animated: animated,
            operation: operation,
            expectsBooleanSuccess: false,
            targetReached: { [weak self] in
                self?.isAtHorizontalProgression(progression) == true
            }
        )
    }

    private func evaluatePositionMutation(
        _ script: String,
        animated: Bool,
        operation: NavigationOperationToken,
        expectsBooleanSuccess: Bool,
        targetReached: @escaping @MainActor () async -> Bool
    ) async -> NavigationResult {
        let animationWait = animated
            ? beginScrollAnimationWait(
                operation: operation,
                targetReached: targetReached
            )
            : nil
        let evaluation = await evaluateScript(
            script,
            operation: operation,
            effect: .positionMutation
        )
        let result = expectsBooleanSuccess
            ? boolScriptResult(evaluation)
            : evaluation.result
        guard result.isApplied else {
            if let animationWait {
                finishScrollAnimationWait(
                    animationWait,
                    with: result,
                    poison: false
                )
            }
            return result
        }
        if let animationWait {
            startScrollAnimationStabilityCheck(animationWait)
            let settled = await waitForScrollAnimation(animationWait)
            guard settled.isApplied else { return settled }
        }
        return operation.check(spreadGeneration: spreadGeneration) ?? .applied
    }

    private func isAtHorizontalProgression(_ progression: Double) -> Bool {
        Self.isAtHorizontalProgression(
            live: leadingProgression,
            requested: progression,
            pageWidth: scrollView.bounds.width,
            contentWidth: scrollView.contentSize.width,
            isRTL: viewModel.readingProgression == .rtl,
            snapsToPage: !(viewModel.scroll && viewModel.verticalText)
        )
    }

    private func boolScriptResult(
        _ result: NavigationValueResult<Any>
    ) -> NavigationResult {
        switch result {
        case let .applied(value):
            return (value as? Bool) == true ? .applied : .spreadNotLoaded
        case let .rejected(result):
            return result
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            await evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))")
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String, animated: Bool) async -> Bool {
        guard let idLiteral = Self.javaScriptStringLiteral(tagID) else {
            return false
        }
        let result = await evaluateScript("readium.scrollToId(\(idLiteral), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else {
            return false
        }
        let result = await evaluateScript("readium.scrollToLocator(\(json), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    override func beginPageTurnSnapshotSuppression() -> () -> Void {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(notifyPagesDidChange),
            object: nil
        )
        let savedProgression = progression
        let savedPreviousProgression = previousProgression
        let hadPendingNotification = savedPreviousProgression != nil
            && savedPreviousProgression != savedProgression
        return { [weak self] in
            guard let self else { return }
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(notifyPagesDidChange),
                object: nil
            )
            self.progression = savedProgression
            self.previousProgression = savedPreviousProgression
            if hadPendingNotification {
                self.setNeedsNotifyPagesDidChange()
            }
        }
    }

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
            !isCapturingPageTurnSnapshot,
            isSpreadLoaded,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        // This callback has no mutation request identity. It may publish the
        // debounced location and may finish the legacy non-token path, but the
        // executor-owned waiter is completed only by its geometry observer.
        finishLegacyScrollAnimation()

        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
        registerJSMessage(named: "contentHeightChanged") { [weak self] in self?.updateContentHeight($0) }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        scheduleNativeReflowableLoadFallback()

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        super.scrollViewDidEndScrollingAnimation(scrollView)
        finishLegacyScrollAnimation()
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        guard !isCapturingPageTurnSnapshot else { return }
        setNeedsNotifyPagesDidChange()
    }
}
