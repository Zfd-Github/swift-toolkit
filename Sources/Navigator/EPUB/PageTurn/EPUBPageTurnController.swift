//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

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

struct PageTurnSession {
    let id = UUID()
    let direction: EPUBSpreadView.Direction
}

@MainActor
final class EPUBPageTurnController {
    private enum State {
        case idle
        case tracking(PageTurnSession)
        case restoring(PageTurnSession)
        case committing(PageTurnSession)

        var session: PageTurnSession? {
            switch self {
            case .idle:
                return nil
            case let .tracking(session), let .restoring(session), let .committing(session):
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

    func begin(to direction: EPUBSpreadView.Direction) -> PageTurnSession? {
        guard isIdle else { return nil }
        let session = PageTurnSession(direction: direction)
        state = .tracking(session)
        return session
    }

    func commit(
        _ session: PageTurnSession,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard
            case let .tracking(activeSession) = state,
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
        case let .tracking(session):
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
