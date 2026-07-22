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
    }

    static func policy(
        axis: PaginationView.Axis,
        style: EPUBPageTurnStyle
    ) -> Policy {
        guard axis == .horizontalPaged else {
            return Policy(
                allowsNativeHorizontalPaging: true,
                usesNonePan: false
            )
        }
        return Policy(
            allowsNativeHorizontalPaging: style == .push,
            usesNonePan: style == .none
        )
    }

    static func direction(
        for velocity: CGPoint,
        readingProgression: ReadingProgression
    ) -> EPUBSpreadView.Direction? {
        guard abs(velocity.x) > abs(velocity.y), velocity.x != 0 else {
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
}

struct PageTurnSession {
    let id = UUID()
    let direction: EPUBSpreadView.Direction
    let readingProgression: ReadingProgression
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
    private var restoreTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let refreshCurrentLocation: () async -> Void

    init(refreshCurrentLocation: @escaping () async -> Void) {
        self.refreshCurrentLocation = refreshCurrentLocation
    }

    var isIdle: Bool {
        state.session == nil
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

    @discardableResult
    func finish(_ session: PageTurnSession) -> Bool {
        guard state.session?.id == session.id else { return false }

        state = .idle
        restoreTask = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return true
    }

    func settle(
        restore: @escaping @MainActor (PageTurnSession) async -> Void
    ) async {
        switch state {
        case .idle:
            break
        case let .tracking(session, _):
            state = .restoring(session)
            if restoreTask == nil {
                restoreTask = Task { @MainActor in
                    await restore(session)
                }
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
