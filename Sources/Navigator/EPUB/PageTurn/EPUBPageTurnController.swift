//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import UIKit

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

    static func policy(
        axis: PaginationView.Axis,
        style: EPUBPageTurnStyle
    ) -> Policy {
        guard axis == .horizontalPaged else {
            return Policy(allowsNativeHorizontalPaging: true)
        }
        return Policy(allowsNativeHorizontalPaging: false)
    }

    static func direction(
        for velocity: CGPoint,
        readingProgression: ReadingProgression
    ) -> EPUBSpreadView.Direction? {
        guard abs(velocity.x) > abs(velocity.y) * 1.2, velocity.x != 0 else {
            return nil
        }

        switch (velocity.x < 0, readingProgression) {
        case (true, .ltr), (false, .rtl):
            return .right
        case (false, .ltr), (true, .rtl):
            return .left
        }
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
        return coverSignedHorizontalValue(
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
            || coverSignedHorizontalValue(
                velocityX,
                session: session
            ) >= 650
    }

    private static func signedHorizontalValue(
        _ value: CGFloat,
        session: PageTurnSession
    ) -> CGFloat {
        switch (session.direction, session.readingProgression) {
        case (.left, .ltr), (.right, .rtl):
            return value
        case (.right, .ltr), (.left, .rtl):
            return -value
        }
    }

    private static func coverSignedHorizontalValue(
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
    }

    private let rootViewProvider: () -> UIView?
    private weak var documentView: UIView?
    private var currentView: UIView
    private var currentRootIdentity: RootIdentity
    private var targetView: UIView?
    private var targetRootIdentity: RootIdentity?
    private let style: EPUBPageTurnStyle
    private let physicalCompletionDirection: EPUBSpreadView.Direction
    private var progress: CGFloat = 0

    convenience init?(
        rootView: UIView,
        documentView: UIView? = nil,
        style: EPUBPageTurnStyle,
        physicalCompletionDirection: EPUBSpreadView.Direction
    ) {
        self.init(
            rootViewProvider: { [weak rootView] in rootView },
            documentView: documentView,
            style: style,
            physicalCompletionDirection: physicalCompletionDirection
        )
    }

    init?(
        rootViewProvider: @escaping () -> UIView?,
        documentView: UIView? = nil,
        style: EPUBPageTurnStyle,
        physicalCompletionDirection: EPUBSpreadView.Direction
    ) {
        guard
            let rootView = rootViewProvider(),
            let parentView = rootView.superview,
            let currentView = rootView.snapshotView(afterScreenUpdates: true)
        else {
            return nil
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
        configure(currentView, role: "current", frame: rootView.frame)
        parentView.insertSubview(currentView, aboveSubview: rootView)
    }

    var hasTarget: Bool {
        targetView != nil
    }

    /// A surface is only safe while at least one of the snapshots which was
    /// installed for this transaction remains mounted. A transient removal of
    /// both snapshots must not be treated as a completed animation.
    var hasMountedSurface: Bool {
        currentView.superview != nil || targetView?.superview != nil
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
        guard
            targetView == nil,
            let rootView = rootViewProvider(),
            let parentView = rootView.superview,
            currentView.superview === parentView,
            let targetView = rootView.snapshotView(afterScreenUpdates: true)
        else {
            return false
        }
        configure(targetView, role: "target", frame: rootView.frame)
        parentView.insertSubview(targetView, aboveSubview: rootView)
        parentView.bringSubviewToFront(currentView)
        self.targetView = targetView
        targetRootIdentity = Self.rootIdentity(
            rootView: rootView,
            documentView: documentView ?? rootView
        )
        render(progress: progress)
        return true
    }

    @discardableResult
    func recaptureTarget() -> Bool {
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
            let replacement = rootView.snapshotView(afterScreenUpdates: true)
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
        render(progress: progress)
        return true
    }

    @discardableResult
    func recaptureCurrent() -> Bool {
        guard
            let rootView = rootViewProvider(),
            let documentView,
            let parentView = rootView.superview,
            let replacement = rootView.snapshotView(afterScreenUpdates: true)
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
        if let targetView, targetView.superview === parentView {
            parentView.bringSubviewToFront(targetView)
            parentView.bringSubviewToFront(currentView)
        }
        render(progress: progress)
        return true
    }

    func render(progress: CGFloat) {
        let progress = min(max(progress, 0), 1)
        self.progress = progress
        guard let rootView = rootViewProvider(), let targetView else { return }
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
            currentView.transform = CGAffineTransform(
                translationX: sign * width * progress,
                y: 0
            )
            targetView.transform = .identity
        case .none, .simulation:
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
        currentView.superview?.bringSubviewToFront(currentView)
    }

    func animate(to progress: CGFloat, duration: TimeInterval) async {
        await withCheckedContinuation { continuation in
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                animations: { self.render(progress: progress) },
                completion: { _ in continuation.resume() }
            )
        }
    }

    func remove() {
        currentView.layer.removeAllAnimations()
        targetView?.layer.removeAllAnimations()
        currentView.removeFromSuperview()
        targetView?.removeFromSuperview()
        targetView = nil
        targetRootIdentity = nil
    }

    private func configure(_ view: UIView, role: String, frame: CGRect) {
        view.frame = frame
        view.autoresizingMask = []
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.accessibilityIdentifier = "readium.page-turn.surface.\(role)"
        view.isUserInteractionEnabled = false
    }

    private static func rootIdentity(rootView: UIView, documentView: UIView) -> RootIdentity {
        rootView.layoutIfNeeded()
        documentView.layoutIfNeeded()
        return RootIdentity(
            root: ObjectIdentifier(rootView),
            parent: rootView.superview.map(ObjectIdentifier.init),
            window: rootView.window.map(ObjectIdentifier.init),
            frame: rootView.frame,
            bounds: rootView.bounds,
            documentFrame: documentView.convert(documentView.bounds, to: rootView),
            scale: rootView.window?.screen.scale ?? rootView.traitCollection.displayScale
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

        let task = Task { @MainActor in
            await operation()
        }
        state = .committing(session)
        let result = await task.value
        if case let .committing(activeSession) = state,
           activeSession.id == session.id {
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
            if await rebound(session) {
                cleanup()
                finish(session)
                return true
            }
        }
        // The caller owns the terminal recovery while the surface stays visible.
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

        if isIdle {
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
