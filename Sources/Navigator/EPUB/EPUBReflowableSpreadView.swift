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
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()

        scrollDidEnd()
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
        scrollView.panGestureRecognizer.isEnabled = !usesContinuousOuterScroll
            && allowsNativeHorizontalPaging
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
            updateContentHeight(await evaluateScript("readium.documentHeight()"))
            scrollView.contentOffset = .zero
            didCompleteGoTo()
        } else {
            let location = pendingLocation
            await go(to: location.location, animated: location.animated)

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

                // Safety net in case `scrollDidEnd` never fires. The identity
                // check on `request` ensures a stale timeout from a previous
                // request does not resume a newer one.
                Task { @MainActor in
                    try? await Task.sleep(seconds: 0.8)
                    scrollDidEnd(for: request)
                }
            }
        }

        return true
    }

    static func pageTurnScrollBehavior(options: NavigatorGoOptions) -> String {
        options.animated ? "smooth" : "instant"
    }

    private struct PendingLocation {
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation = .init(location: .start, animated: false)

    override func go(to location: PageLocation, animated: Bool) async {
        if usesContinuousOuterScroll {
            guard isSpreadLoaded else {
                pendingLocation = PendingLocation(location: location, animated: animated)
                await waitGoToCompletion()
                return
            }

            didCompleteGoTo()
            return
        }

        guard isSpreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = PendingLocation(location: location, animated: animated)

            await waitGoToCompletion()
            return
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
    }

    private func waitGoToCompletion() async {
        guard !didReportNavigationFailure else {
            return
        }
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    private func didCompleteGoTo() {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func scrollDidEnd(for request: ScrollAnimationRequest? = nil) {
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

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator, animated: animated)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            return await scroll(toTagID: id, animated: animated)
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression, animated: animated)
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
        let result = await evaluateScript("readium.scrollToId(\'\(tagID)\', \(animated));")
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

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
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
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
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

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }
}
