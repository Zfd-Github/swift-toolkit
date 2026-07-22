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
        let usesNonePan: Bool
        let usesCoverPan: Bool
    }

    static func policy(
        axis: PaginationView.Axis,
        style: EPUBPageTurnStyle
    ) -> Policy {
        guard axis == .horizontalPaged else {
            return Policy(
                allowsNativeHorizontalPaging: true,
                usesNonePan: false,
                usesCoverPan: false
            )
        }
        return Policy(
            allowsNativeHorizontalPaging: style == .push,
            usesNonePan: style == .none,
            usesCoverPan: style == .cover
        )
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
final class EPUBCoverPageTurnAnimator {
    struct Geometry: Equatable {
        let currentX: CGFloat
        let targetX: CGFloat
        let shadowAlpha: CGFloat
    }

    private let currentView: UIImageView
    private let targetView: UIImageView
    private let shadowView = UIView()
    private let isForward: Bool
    private let physicalCompletionDirection: EPUBSpreadView.Direction
    private weak var hostView: UIView?

    init(
        hostView: UIView,
        currentImage: UIImage,
        targetImage: UIImage,
        isForward: Bool,
        physicalCompletionDirection: EPUBSpreadView.Direction
    ) {
        self.hostView = hostView
        self.isForward = isForward
        self.physicalCompletionDirection = physicalCompletionDirection
        currentView = Self.makeImageView(image: currentImage, frame: hostView.bounds)
        targetView = Self.makeImageView(image: targetImage, frame: hostView.bounds)

        shadowView.frame = CGRect(x: 0, y: 0, width: 12, height: hostView.bounds.height)
        shadowView.autoresizingMask = [.flexibleHeight]
        shadowView.backgroundColor = UIColor.black
        shadowView.isAccessibilityElement = false
        shadowView.accessibilityElementsHidden = true
        shadowView.isUserInteractionEnabled = false

        if isForward {
            hostView.addSubview(targetView)
            hostView.addSubview(currentView)
        } else {
            hostView.addSubview(currentView)
            hostView.addSubview(targetView)
        }
        hostView.addSubview(shadowView)
        render(progress: 0)
    }

    static func geometry(
        progress: CGFloat,
        viewportWidth: CGFloat,
        isForward: Bool,
        physicalCompletionDirection: EPUBSpreadView.Direction
    ) -> Geometry {
        let progress = min(max(progress, 0), 1)
        let travelSign: CGFloat = physicalCompletionDirection == .left ? -1 : 1
        return Geometry(
            currentX: isForward ? travelSign * viewportWidth * progress : 0,
            targetX: isForward ? 0 : -travelSign * viewportWidth * (1 - progress),
            shadowAlpha: 0.18 * (1 - abs(2 * progress - 1))
        )
    }

    func render(progress: CGFloat) {
        guard let hostView else { return }
        let geometry = Self.geometry(
            progress: progress,
            viewportWidth: hostView.bounds.width,
            isForward: isForward,
            physicalCompletionDirection: physicalCompletionDirection
        )
        currentView.transform = CGAffineTransform(translationX: geometry.currentX, y: 0)
        targetView.transform = CGAffineTransform(translationX: geometry.targetX, y: 0)
        shadowView.alpha = geometry.shadowAlpha

        let movingX = isForward ? geometry.currentX : geometry.targetX
        let shadowX: CGFloat
        switch (isForward, physicalCompletionDirection) {
        case (true, .left), (false, .right):
            shadowX = hostView.bounds.width - shadowView.bounds.width
        case (true, .right), (false, .left):
            shadowX = 0
        }
        shadowView.transform = CGAffineTransform(translationX: movingX + shadowX, y: 0)
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
        currentView.removeFromSuperview()
        targetView.removeFromSuperview()
        shadowView.removeFromSuperview()
    }

    private static func makeImageView(image: UIImage, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: image)
        view.frame = frame
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        return view
    }
}

@MainActor
final class EPUBPageTurnController {
    private enum State {
        case idle
        case tracking(PageTurnSession, progress: CGFloat)
        case restoring(PageTurnSession)
        case committing(PageTurnSession)

        var session: PageTurnSession? {
            switch self {
            case .idle:
                return nil
            case let .tracking(session, _), let .restoring(session), let .committing(session):
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
        return await task.value
    }

    func turnProgrammatically(
        _ session: PageTurnSession,
        animate: @escaping @MainActor () async -> Void,
        performPageTurn: @escaping @MainActor () async -> Bool,
        publishCurrentLocation: @escaping @MainActor () async -> Void,
        finish: @escaping @MainActor () -> Void
    ) async -> Bool {
        await animate()
        if Task.isCancelled {
            if isTracking(session) {
                finish()
            }
            return false
        }
        return await commit(session) {
            let moved = await performPageTurn()
            if moved {
                await publishCurrentLocation()
            }
            finish()
            return moved
        }
    }

    func restoreCover(
        _ session: PageTurnSession,
        rebound: @escaping @MainActor (PageTurnSession) async -> Void,
        cleanup: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor (PageTurnSession) -> Void
    ) async -> Bool {
        guard
            case let .tracking(activeSession, _) = state,
            activeSession.id == session.id
        else {
            return false
        }
        state = .restoring(session)
        await rebound(session)
        cleanup()
        finish(session)
        return true
    }

    func settleCover(
        settleSnapshots: @escaping @MainActor () async -> Void = {},
        rebound: @escaping @MainActor (PageTurnSession) async -> Void,
        cleanup: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor (PageTurnSession) -> Void
    ) async {
        switch state {
        case .idle:
            await settleSnapshots()
        case let .tracking(session, _):
            state = .restoring(session)
            Task { @MainActor in
                await settleSnapshots()
                await rebound(session)
                cleanup()
                finish(session)
            }
            await waitUntilIdle()
            await settleSnapshots()
        case .restoring, .committing:
            await waitUntilIdle()
            await settleSnapshots()
        }

        await refreshCurrentLocation()
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
        case .idle, .restoring, .committing:
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
            state = .restoring(session)
            Task { @MainActor in
                await restore(session)
            }
            await waitUntilIdle()
        case .restoring, .committing:
            await waitUntilIdle()
        }

        await refreshCurrentLocation()
    }

    private func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}
