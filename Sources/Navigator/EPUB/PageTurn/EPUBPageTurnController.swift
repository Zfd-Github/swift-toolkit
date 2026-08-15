//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import QuartzCore
import UIKit

@MainActor
protocol EPUBPageTurnSurfaceSnapshotProviding: AnyObject {
    func pageTurnSurfaceSnapshot(afterScreenUpdates: Bool) -> UIView?
}

public enum EPUBPageTurnStyle: Sendable, Equatable {
    case simulation
    case cover
    case push
    case none
}

extension EPUBPageTurnStyle {
    static func effective(
        userStyle: EPUBPageTurnStyle,
        isReduceMotionEnabled: Bool,
        isVoiceOverRunning: Bool
    ) -> EPUBPageTurnStyle {
        guard !isReduceMotionEnabled, !isVoiceOverRunning else {
            return .none
        }
        return userStyle
    }
}

enum EPUBPageTurnInteraction {
    struct Policy: Equatable {
        let allowsNativeHorizontalPaging: Bool
    }

    /// Horizontal page-turn styles share one pan policy: native paging is off
    /// so the navigator owns the gesture. Continuous axes keep native paging.
    static func policy(axis: PaginationView.Axis) -> Policy {
        guard axis == .horizontalPaged else {
            return Policy(allowsNativeHorizontalPaging: true)
        }
        return Policy(allowsNativeHorizontalPaging: false)
    }

    static func discreteNavigationOptions(
        _ options: NavigatorGoOptions,
        axis: PaginationView.Axis?,
        style: EPUBPageTurnStyle
    ) -> NavigatorGoOptions {
        guard
            axis == .horizontalPaged,
            style == .simulation,
            case let .string(direction)? = options.otherOptions["readium.epub.pageTurnDirection"],
            direction == "forward" || direction == "backward"
        else {
            guard axis == .horizontalPaged, style == .simulation else {
                return options
            }
            var options = options
            options.animated = false
            return options
        }
        return options
    }

    /// Maps a primarily horizontal velocity to a spread direction.
    /// Reading progression is applied later via `PageTurnSession.isForward`.
    static func direction(for velocity: CGPoint) -> EPUBSpreadView.Direction? {
        guard abs(velocity.x) > abs(velocity.y) * 1.2, velocity.x != 0 else {
            return nil
        }
        return velocity.x < 0 ? .right : .left
    }

    static func progress(
        translationX: CGFloat,
        viewportWidth: CGFloat,
        session: PageTurnSession
    ) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        return signedHorizontalValue(
            translationX,
            session: session
        ) / viewportWidth
    }

    static func shouldCommit(
        translationX: CGFloat,
        viewportWidth: CGFloat,
        velocityX: CGFloat,
        session: PageTurnSession
    ) -> Bool {
        progress(
            translationX: translationX,
            viewportWidth: viewportWidth,
            session: session
        ) >= 0.22
            || signedHorizontalValue(
                velocityX,
                session: session
            ) >= 650
    }

    static func coverDirection(
        for velocity: CGPoint
    ) -> EPUBSpreadView.Direction? {
        guard abs(velocity.x) > abs(velocity.y) * 1.2, velocity.x != 0 else {
            return nil
        }
        return velocity.x < 0 ? .right : .left
    }

    static func coverProgress(
        translationX: CGFloat,
        viewportWidth: CGFloat,
        session: PageTurnSession
    ) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        return signedHorizontalValue(
            translationX,
            session: session
        ) / viewportWidth
    }

    static func coverShouldCommit(
        translationX: CGFloat,
        viewportWidth: CGFloat,
        velocityX: CGFloat,
        session: PageTurnSession
    ) -> Bool {
        coverProgress(
            translationX: translationX,
            viewportWidth: viewportWidth,
            session: session
        ) >= 0.22
            || signedHorizontalValue(
                velocityX,
                session: session
            ) >= 650
    }

    private static func signedHorizontalValue(
        _ value: CGFloat,
        session: PageTurnSession
    ) -> CGFloat {
        session.physicalCompletionDirection == .left ? -value : value
    }
}

@MainActor
final class EPUBPageTurnSurfaceAnimator {
    private struct RootIdentity: Equatable {
        let root: ObjectIdentifier
        let parent: ObjectIdentifier?
        let window: ObjectIdentifier?
        let frame: CGRect
        let bounds: CGRect
        let documentFrame: CGRect
        let scale: CGFloat
        /// Color appearance / contrast so theme flips invalidate captured surfaces.
        let userInterfaceStyle: Int
        let accessibilityContrast: Int
    }

    private let rootViewProvider: () -> UIView?
    private weak var documentView: UIView?
    private var currentView: UIView
    private var currentRootIdentity: RootIdentity
    private var targetView: UIView?
    private var targetRootIdentity: RootIdentity?
    private var pageCurlController: EPUBPageCurlController?
    private var activeFrameWaiter: PageTurnAnimationFrameWaiter?
    private let style: EPUBPageTurnStyle
    private let physicalCompletionDirection: EPUBSpreadView.Direction
    /// Reading-order forward peels/slides current; backward covers with the target page.
    private let isForward: Bool
    private let paperColor: UIColor
    private var progress: CGFloat = 0
    /// Opaque freeze kept above all turn surfaces while prepare navigates and
    /// captures the target. Without it, `snapshotView(afterScreenUpdates:)` can
    /// briefly composite the live next page (tap-path flash). Swipe is less
    /// sensitive because the user is already mid-gesture.
    private var prepareShield: UIView?

    private static func snapshotView(of view: UIView) -> UIView? {
        // UIKit can wait indefinitely for a RenderServer commit when asked to
        // update an off-window hierarchy. There is no committed screen content
        // to refresh in that state, so capture the hierarchy as-is instead.
        let afterScreenUpdates = view.window != nil
        if let provider = view as? EPUBPageTurnSurfaceSnapshotProviding {
            return provider.pageTurnSurfaceSnapshot(
                afterScreenUpdates: afterScreenUpdates
            )
        }
        if afterScreenUpdates {
            return view.snapshotView(afterScreenUpdates: true)
        }
        if let snapshot = view.snapshotView(afterScreenUpdates: false) {
            return snapshot
        }
        guard let image = EPUBPageCurlController.rasterize(view) else { return nil }
        return UIImageView(image: image)
    }

    convenience init?(
        rootView: UIView,
        documentView: UIView? = nil,
        style: EPUBPageTurnStyle,
        physicalCompletionDirection: EPUBSpreadView.Direction,
        isForward: Bool
    ) {
        self.init(
            rootViewProvider: { [weak rootView] in rootView },
            documentView: documentView,
            style: style,
            physicalCompletionDirection: physicalCompletionDirection,
            isForward: isForward
        )
    }

    init?(
        rootViewProvider: @escaping () -> UIView?,
        documentView: UIView? = nil,
        style: EPUBPageTurnStyle,
        physicalCompletionDirection: EPUBSpreadView.Direction,
        isForward: Bool
    ) {
        guard
            let rootView = rootViewProvider(),
            let parentView = rootView.superview,
            let currentView = Self.snapshotView(of: rootView)
        else {
            return nil
        }
        let paperColor = (
            rootView.backgroundColor
                ?? parentView.backgroundColor
                ?? .systemBackground
        ).resolvedColor(with: rootView.traitCollection)
        let pageCurlController: EPUBPageCurlController?
        if style == .simulation {
            guard
                let image = EPUBPageCurlController.rasterize(rootView)?.cgImage,
                let controller = EPUBPageCurlController(
                    currentImage: image,
                    paperColor: paperColor,
                    isForward: isForward
                )
            else {
                return nil
            }
            pageCurlController = controller
        } else {
            pageCurlController = nil
        }
        self.rootViewProvider = rootViewProvider
        self.documentView = documentView ?? rootView
        self.currentView = currentView
        currentRootIdentity = Self.rootIdentity(
            rootView: rootView,
            documentView: documentView ?? rootView
        )
        self.style = style
        self.physicalCompletionDirection = physicalCompletionDirection
        self.isForward = isForward
        self.paperColor = paperColor
        self.pageCurlController = pageCurlController
        configure(currentView, role: "current", frame: rootView.frame)
        parentView.insertSubview(currentView, aboveSubview: rootView)
        if let pageCurlController {
            let renderView = pageCurlController.view
            configureCurlView(renderView, frame: rootView.frame)
            parentView.insertSubview(renderView, aboveSubview: currentView)
        }
        // Install before any prepare navigation / afterScreenUpdates capture.
        installPrepareShield(over: rootView, in: parentView)
    }

    var hasTarget: Bool {
        targetView != nil
    }

    /// A surface is only safe while at least one of the snapshots which was
    /// installed for this transaction remains mounted. A transient removal of
    /// both snapshots must not be treated as a completed animation.
    var hasMountedSurface: Bool {
        currentView.superview != nil
            || targetView?.superview != nil
            || pageCurlController?.view.superview != nil
    }

    var hasMatchingCurrentRootIdentity: Bool {
        guard let rootView = rootViewProvider(), let documentView else { return false }
        return currentRootIdentity == Self.rootIdentity(
            rootView: rootView,
            documentView: documentView
        )
    }

    var hasMatchingTargetRootIdentity: Bool {
        guard
            let rootView = rootViewProvider(),
            let documentView,
            let targetRootIdentity
        else {
            return false
        }
        return targetRootIdentity == Self.rootIdentity(
            rootView: rootView,
            documentView: documentView
        )
    }

    @discardableResult
    func captureTarget() -> Bool {
        guard let rootView = rootViewProvider() else { return false }
        let curlImage = style == .simulation
            ? EPUBPageCurlController.rasterize(rootView)?.cgImage
            : nil
        guard
            targetView == nil,
            let parentView = rootView.superview,
            currentView.superview === parentView,
            let targetView = Self.snapshotView(of: rootView),
            style != .simulation || curlImage != nil
        else {
            return false
        }
        configure(targetView, role: "target", frame: rootView.frame)
        parentView.insertSubview(targetView, aboveSubview: rootView)
        // Match pre-regression order: keep current above the newly inserted
        // target immediately (HEAD), before any transform work.
        parentView.bringSubviewToFront(currentView)
        self.targetView = targetView
        targetRootIdentity = Self.rootIdentity(
            rootView: rootView,
            documentView: documentView ?? rootView
        )
        if
            style == .simulation,
            let image = curlImage,
            let pageCurlController
        {
            pageCurlController.setTargetImage(image)
            let renderView = pageCurlController.view
            configureCurlView(renderView, frame: rootView.frame)
            if renderView.superview !== parentView {
                parentView.insertSubview(renderView, aboveSubview: currentView)
            }
        }
        // Position first so cover-backward target is off-screen before it rises.
        syncPrepareShieldFrame(to: rootView)
        render(progress: progress)
        applySurfaceStacking(in: parentView)
        bringPrepareShieldToFront(in: parentView)
        return true
    }

    @discardableResult
    func recaptureTarget() -> Bool {
        pageCurlController?.view.removeFromSuperview()
        currentView.isHidden = false
        targetView?.removeFromSuperview()
        targetView = nil
        targetRootIdentity = nil
        return captureTarget()
    }

    @discardableResult
    func recaptureCommittedTarget() -> Bool {
        guard
            let rootView = rootViewProvider(),
            let documentView,
            let parentView = rootView.superview,
            let replacement = Self.snapshotView(of: rootView)
        else {
            return false
        }
        configure(replacement, role: "target", frame: rootView.frame)
        parentView.insertSubview(replacement, aboveSubview: rootView)
        targetView?.removeFromSuperview()
        targetView = replacement
        targetRootIdentity = Self.rootIdentity(
            rootView: rootView,
            documentView: documentView
        )
        if
            style == .simulation,
            let image = EPUBPageCurlController.rasterize(rootView)?.cgImage,
            let pageCurlController
        {
            pageCurlController.setTargetImage(image)
            pageCurlController.view.frame = rootView.frame
            parentView.insertSubview(pageCurlController.view, aboveSubview: currentView)
        }
        syncPrepareShieldFrame(to: rootView)
        render(progress: progress)
        applySurfaceStacking(in: parentView)
        bringPrepareShieldToFront(in: parentView)
        return true
    }

    @discardableResult
    func recaptureCurrent() -> Bool {
        guard
            let rootView = rootViewProvider(),
            let documentView,
            let parentView = rootView.superview,
            let replacement = Self.snapshotView(of: rootView)
        else {
            return false
        }
        configure(replacement, role: "current", frame: rootView.frame)
        parentView.insertSubview(replacement, aboveSubview: rootView)
        currentView.removeFromSuperview()
        currentView = replacement
        currentRootIdentity = Self.rootIdentity(
            rootView: rootView,
            documentView: documentView
        )
        if
            style == .simulation,
            let image = EPUBPageCurlController.rasterize(rootView)?.cgImage
        {
            pageCurlController?.setCurrentImage(image)
        }
        // Layout may have changed since prepare (rotation / split view). Keep
        // the freeze mask covering the full root so the live next page cannot
        // flash through uncovered edges.
        syncPrepareShieldFrame(to: rootView)
        render(progress: progress)
        applySurfaceStacking(in: parentView)
        bringPrepareShieldToFront(in: parentView)
        return true
    }

    func render(progress: CGFloat) {
        let progress = min(max(progress, 0), 1)
        self.progress = progress
        guard let rootView = rootViewProvider() else { return }
        if style == .simulation {
            // The current-page curl is mounted as soon as prepare starts, so a
            // cold target can track the gesture while WebKit loads. Capturing
            // the target later replaces only the texture, not the live surface.
            pageCurlController?.render(progress: progress)
            currentView.transform = .identity
            targetView?.transform = .identity
            return
        }
        guard let targetView else { return }
        let width = rootView.bounds.width
        let sign: CGFloat = physicalCompletionDirection == .left ? -1 : 1
        switch style {
        case .push:
            currentView.transform = CGAffineTransform(
                translationX: sign * width * progress,
                y: 0
            )
            targetView.transform = CGAffineTransform(
                translationX: -sign * width * (1 - progress),
                y: 0
            )
        case .cover:
            // Forward: current slides out, revealing still target underneath.
            // Backward: target slides in from the outer side and covers current.
            if isForward {
                currentView.transform = CGAffineTransform(
                    translationX: sign * width * progress,
                    y: 0
                )
                targetView.transform = .identity
            } else {
                currentView.transform = .identity
                targetView.transform = CGAffineTransform(
                    translationX: -sign * width * (1 - progress),
                    y: 0
                )
            }
        case .simulation:
            assertionFailure("simulation rendering returns before this switch")
        case .none:
            currentView.transform = .identity
            targetView.transform = .identity
        }
    }

    /// Keeps the original-page snapshot above the live reader while a cancelled
    /// turn is waiting for an exact recovery.
    func retainCurrentSurfaceForSafety() {
        guard
            let rootView = rootViewProvider(),
            currentView.superview === rootView.superview
        else {
            return
        }
        currentView.transform = .identity
        currentView.frame = rootView.frame
        targetView?.isHidden = true
        if style == .simulation {
            pageCurlController?.render(progress: 0)
            if let renderView = pageCurlController?.view {
                renderView.isHidden = false
                renderView.superview?.bringSubviewToFront(renderView)
            }
        } else {
            currentView.superview?.bringSubviewToFront(currentView)
        }
    }

    func animate(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        scheduleDisplayFrame: (@MainActor (PageTurnAnimationFrameWaiter) -> Void)? = nil,
        shouldContinue: @MainActor @escaping () -> Bool = { true }
    ) async -> Bool {
        // Prepare finished; show real turn surfaces for the animation.
        dismissPrepareShield()
        if style == .simulation, let pageCurlController {
            progress = min(max(targetProgress, 0), 1)
            return await pageCurlController.animate(
                to: targetProgress,
                duration: duration,
                scheduleDisplayFrame: scheduleDisplayFrame,
                shouldContinue: shouldContinue
            )
        }
        // Frame-driven interpolation so reduce-motion / background cancel can
        // interrupt push/cover mid-flight (UIView.animate is not cancellable).
        let startProgress = progress
        let endProgress = min(max(targetProgress, 0), 1)
        guard duration > 0 else {
            guard shouldContinue() else { return false }
            render(progress: endProgress)
            return true
        }
        // A cancelled parent Task makes PageTurnAnimationFrameWaiter return
        // immediately. Snap to the end state instead of busy-waiting for
        // wall-clock duration on the main actor (restore after prepare cancel).
        if Task.isCancelled {
            render(progress: endProgress)
            return shouldContinue()
        }
        let startTime = CACurrentMediaTime()
        var elapsed: TimeInterval = 0
        while elapsed < duration {
            guard shouldContinue() else { return false }
            if Task.isCancelled {
                render(progress: endProgress)
                return shouldContinue()
            }
            if let scheduleDisplayFrame {
                await PageTurnAnimationFrameWaiter.wait(
                    scheduleDisplayFrame: scheduleDisplayFrame,
                    registerWaiter: { self.activeFrameWaiter = $0 }
                )
            } else {
                await PageTurnAnimationFrameWaiter.wait(
                    registerWaiter: { self.activeFrameWaiter = $0 }
                )
            }
            activeFrameWaiter = nil
            if Task.isCancelled {
                render(progress: endProgress)
                return shouldContinue()
            }
            guard shouldContinue() else { return false }
            elapsed = CACurrentMediaTime() - startTime
            let fraction = min(max(elapsed / duration, 0), 1)
            let eased = 1 - pow(1 - fraction, 3)
            render(progress: startProgress + (endProgress - startProgress) * eased)
        }
        render(progress: endProgress)
        return true
    }

    func cancelAnimation() {
        pageCurlController?.cancelAnimation()
        activeFrameWaiter?.cancel()
        activeFrameWaiter = nil
    }

    func remove() {
        cancelAnimation()
        dismissPrepareShield()
        currentView.layer.removeAllAnimations()
        targetView?.layer.removeAllAnimations()
        currentView.removeFromSuperview()
        targetView?.removeFromSuperview()
        pageCurlController?.view.removeFromSuperview()
        targetView = nil
        targetRootIdentity = nil
    }

    /// Drops the prepare freeze so interactive tracking / animation can show.
    func dismissPrepareShield() {
        prepareShield?.removeFromSuperview()
        prepareShield = nil
    }

    private func installPrepareShield(over rootView: UIView, in parentView: UIView) {
        dismissPrepareShield()
        // Prefer an opaque raster (no transparent holes from snapshotView).
        let shield: UIView
        if let image = EPUBPageCurlController.rasterize(rootView) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            shield = imageView
        } else if let snap = currentView.snapshotView(afterScreenUpdates: false) {
            shield = snap
        } else {
            let fill = UIView()
            fill.backgroundColor = paperColor
            shield = fill
        }
        // Do not use `surface.*` accessibility ids — probes treat those as
        // turn surfaces and would keep tracking until the shield is cleared.
        // Follow the root's edges when the parent resizes (rotation / split
        // view). `recaptureCurrent` also hard-syncs the frame in case the root
        // moves independently of the parent.
        shield.frame = rootView.frame
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shield.backgroundColor = paperColor
        shield.isOpaque = true
        shield.isAccessibilityElement = false
        shield.accessibilityElementsHidden = true
        shield.accessibilityIdentifier = "readium.page-turn.prepare-shield"
        shield.isUserInteractionEnabled = false
        parentView.addSubview(shield)
        parentView.bringSubviewToFront(shield)
        prepareShield = shield
    }

    /// Keeps the prepare freeze covering the live root after layout changes
    /// (rotation, split view, root replacement) so the next page cannot flash
    /// through uncovered regions.
    private func syncPrepareShieldFrame(to rootView: UIView) {
        prepareShield?.frame = rootView.frame
    }

    private func bringPrepareShieldToFront(in parentView: UIView) {
        if let prepareShield {
            parentView.bringSubviewToFront(prepareShield)
        }
    }

    private func configure(_ view: UIView, role: String, frame: CGRect) {
        view.frame = frame
        view.autoresizingMask = []
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.accessibilityIdentifier = "readium.page-turn.surface.\(role)"
        view.isUserInteractionEnabled = false
    }

    private func configureCurlView(_ view: UIView, frame: CGRect) {
        view.frame = frame
        view.autoresizingMask = []
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.accessibilityIdentifier = "readium.page-turn.curl"
        view.isUserInteractionEnabled = false
    }

    /// Cover backward keeps the incoming target above current; every other
    /// style keeps current (and optional curl) as the top occlusion layer.
    private func applySurfaceStacking(in parentView: UIView) {
        switch style {
        case .cover where !isForward:
            parentView.bringSubviewToFront(currentView)
            if let targetView {
                parentView.bringSubviewToFront(targetView)
            }
        case .simulation:
            parentView.bringSubviewToFront(currentView)
            if let targetView {
                parentView.bringSubviewToFront(targetView)
            }
            if let curl = pageCurlController?.view, curl.superview === parentView {
                parentView.bringSubviewToFront(curl)
            }
        default:
            // HEAD behavior: current stays the top occlusion layer.
            parentView.bringSubviewToFront(currentView)
        }
        bringPrepareShieldToFront(in: parentView)
    }

    private static func rootIdentity(rootView: UIView, documentView: UIView) -> RootIdentity {
        rootView.layoutIfNeeded()
        documentView.layoutIfNeeded()
        let traits = rootView.traitCollection
        return RootIdentity(
            root: ObjectIdentifier(rootView),
            parent: rootView.superview.map(ObjectIdentifier.init),
            window: rootView.window.map(ObjectIdentifier.init),
            frame: rootView.frame,
            bounds: rootView.bounds,
            documentFrame: documentView.convert(documentView.bounds, to: rootView),
            scale: rootView.window?.screen.scale ?? traits.displayScale,
            userInterfaceStyle: traits.userInterfaceStyle.rawValue,
            accessibilityContrast: traits.accessibilityContrast.rawValue
        )
    }
}

struct PageTurnSession {
    let id = UUID()
    let direction: EPUBSpreadView.Direction
    let readingProgression: ReadingProgression

    var isForward: Bool {
        switch (direction, readingProgression) {
        case (.right, .ltr), (.left, .rtl):
            return true
        case (.left, .ltr), (.right, .rtl):
            return false
        }
    }

    var physicalCompletionDirection: EPUBSpreadView.Direction {
        direction == .right ? .left : .right
    }
}

@MainActor
final class EPUBPageTurnController {
    private enum State {
        case idle
        case tracking(PageTurnSession, progress: CGFloat)
        case settling(PageTurnSession)
        case restoring(PageTurnSession)
        case committing(PageTurnSession)

        var session: PageTurnSession? {
            switch self {
            case .idle:
                return nil
            case let .tracking(session, _), let .settling(session),
                 let .restoring(session), let .committing(session):
                return session
            }
        }
    }

    private var state: State = .idle
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let refreshCurrentLocation: () async -> Void

    init(refreshCurrentLocation: @escaping () async -> Void) {
        self.refreshCurrentLocation = refreshCurrentLocation
    }

    var isIdle: Bool {
        state.session == nil
    }

    var activeSession: PageTurnSession? {
        state.session
    }

    var isCommitting: Bool {
        if case .committing = state {
            return true
        }
        return false
    }

    func isTracking(_ session: PageTurnSession) -> Bool {
        guard case let .tracking(activeSession, _) = state else { return false }
        return activeSession.id == session.id
    }

    func begin(
        to direction: EPUBSpreadView.Direction,
        readingProgression: ReadingProgression
    ) -> PageTurnSession? {
        guard isIdle else { return nil }
        let session = PageTurnSession(
            direction: direction,
            readingProgression: readingProgression
        )
        state = .tracking(session, progress: 0)
        return session
    }

    func track(
        _ session: PageTurnSession,
        translationX: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat? {
        guard
            case let .tracking(activeSession, _) = state,
            activeSession.id == session.id
        else {
            return nil
        }

        let progress = EPUBPageTurnInteraction.progress(
            translationX: translationX,
            viewportWidth: viewportWidth,
            session: session
        )
        state = .tracking(session, progress: progress)
        return progress
    }

    func trackCover(
        _ session: PageTurnSession,
        translationX: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat? {
        guard
            case let .tracking(activeSession, _) = state,
            activeSession.id == session.id
        else {
            return nil
        }

        let progress = EPUBPageTurnInteraction.coverProgress(
            translationX: translationX,
            viewportWidth: viewportWidth,
            session: session
        )
        state = .tracking(session, progress: progress)
        return progress
    }

    func commit(
        _ session: PageTurnSession,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard
            case let .tracking(activeSession, _) = state,
            activeSession.id == session.id
        else {
            return false
        }

        state = .committing(session)
        let result = await operation()
        if case let .committing(activeSession) = state,
           activeSession.id == session.id
        {
            _ = finish(session)
        }
        return result
    }

    func restorePreparedPage(
        inverse: @escaping @MainActor () async -> Bool,
        validateOriginalLocation: @escaping @MainActor () async -> Bool,
        originalLocation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        if await inverse(), await validateOriginalLocation() {
            return true
        }
        guard await originalLocation() else { return false }
        return await validateOriginalLocation()
    }

    func restoreCover(
        _ session: PageTurnSession,
        rebound: @escaping @MainActor (PageTurnSession) async -> Bool,
        cleanup: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor (PageTurnSession) -> Void
    ) async -> Bool {
        let activeSession: PageTurnSession?
        switch state {
        case let .tracking(active, _), let .settling(active):
            activeSession = active
        case .idle, .restoring, .committing:
            activeSession = nil
        }
        guard activeSession?.id == session.id else {
            return false
        }
        state = .restoring(session)
        for _ in 0 ..< 2 {
            let restored = await rebound(session)
            guard
                !Task.isCancelled,
                case let .restoring(activeSession) = state,
                activeSession.id == session.id
            else {
                return false
            }
            if restored {
                cleanup()
                finish(session)
                return true
            }
        }
        // The caller owns the terminal recovery while the surface stays visible.
        guard
            !Task.isCancelled,
            case let .restoring(activeSession) = state,
            activeSession.id == session.id
        else {
            return false
        }
        state = .tracking(session, progress: 0)
        return false
    }

    @discardableResult
    func finish(_ session: PageTurnSession) -> Bool {
        guard state.session?.id == session.id else { return false }

        state = .idle
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return true
    }

    func invalidatePreCommitSession() -> PageTurnSession? {
        switch state {
        case let .tracking(session, _):
            return finish(session) ? session : nil
        case .idle, .settling, .restoring, .committing:
            return nil
        }
    }

    func settle(
        restore: @escaping @MainActor (PageTurnSession) async -> Void
    ) async {
        switch state {
        case .idle:
            break
        case let .tracking(session, _):
            state = .settling(session)
            await restore(session)
            if isTracking(session) {
                _ = finish(session)
            }
        case .settling, .restoring, .committing:
            await waitUntilIdle()
        }

        await refreshCurrentLocation()
    }

    func settleRecovering(
        refreshCurrentLocation shouldRefreshCurrentLocation: Bool = true,
        _ recovering: @escaping @MainActor (PageTurnSession) async -> Bool
    ) async {
        switch state {
        case .idle:
            break
        case let .tracking(session, _):
            state = .settling(session)
            let restored = await recovering(session)
            if restored, isTracking(session) {
                _ = finish(session)
            }
        case .settling, .restoring, .committing:
            await waitUntilIdle()
        }

        if isIdle, shouldRefreshCurrentLocation {
            await refreshCurrentLocation()
        }
    }

    private func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}
