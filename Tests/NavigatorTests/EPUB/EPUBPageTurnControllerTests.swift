//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

@MainActor
@Suite(.serialized)
struct EPUBPageTurnControllerTests {
    @Test("page turn style defaults to push and changes without presentation callbacks")
    func configurationAndRuntimeStyle() throws {
        let config = EPUBNavigatorViewController.Configuration()
        #expect(config.pageTurnStyle == .push)

        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Test"))
        )
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: nil,
            config: config
        )
        let delegate = Delegate()
        navigator.delegate = delegate

        navigator.pageTurnStyle = .none

        #expect(navigator.pageTurnStyle == .none)
        #expect(delegate.presentationChangeCount == 0)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.errorCount == 0)
    }

    @Test("reduce motion or VoiceOver resolves every user style to none")
    func accessibilityStyle() {
        let styles: [EPUBPageTurnStyle] = [.simulation, .cover, .push, .none]

        for style in styles {
            #expect(EPUBPageTurnStyle.effective(
                userStyle: style,
                isReduceMotionEnabled: false,
                isVoiceOverRunning: false
            ) == style)
            #expect(EPUBPageTurnStyle.effective(
                userStyle: style,
                isReduceMotionEnabled: true,
                isVoiceOverRunning: false
            ) == .none)
            #expect(EPUBPageTurnStyle.effective(
                userStyle: style,
                isReduceMotionEnabled: false,
                isVoiceOverRunning: true
            ) == .none)
        }
    }

    @Test("a second page turn is rejected until the active session finishes")
    func concurrentTurnIsRejected() {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = controller.begin(to: .right)

        #expect(session != nil)
        #expect(controller.begin(to: .left) == nil)
        #expect(session.map(controller.finish) == true)
        #expect(controller.isIdle)
    }

    @Test("settle without an active turn still awaits a location refresh")
    func idleSettleAwaitsLocationRefresh() async {
        let refreshGate = Gate()
        var refreshCount = 0
        let controller = EPUBPageTurnController {
            refreshCount += 1
            await refreshGate.wait()
        }
        var didSettle = false

        let settleTask = Task { @MainActor in
            await controller.settle(restore: { _ in })
            didSettle = true
        }

        #expect(await waitUntil { refreshCount == 1 })
        #expect(!didSettle)
        refreshGate.open()
        await settleTask.value
        #expect(didSettle)
        #expect(refreshCount == 1)
    }

    @Test("tracking restore is shared and wakes every settle waiter")
    func trackingRestoreWakesMultipleWaiters() async throws {
        let restoreGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right))
        var restoreCount = 0
        var settledCount = 0

        let restore: (PageTurnSession) async -> Void = { restoredSession in
            restoreCount += 1
            #expect(restoredSession.id == session.id)
            await restoreGate.wait()
            #expect(controller.finish(restoredSession))
        }
        let first = Task { @MainActor in
            await controller.settle(restore: restore)
            settledCount += 1
        }
        let second = Task { @MainActor in
            await controller.settle(restore: restore)
            settledCount += 1
        }

        #expect(await waitUntil { restoreCount == 1 })
        #expect(settledCount == 0)
        restoreGate.open()
        await first.value
        await second.value

        #expect(restoreCount == 1)
        #expect(settledCount == 2)
        #expect(controller.isIdle)
    }

    @Test("cancellation and settle wait for irreversible handoff, publish, and release")
    func committedTurnIgnoresCancellation() async throws {
        let handoffGate = Gate()
        let publishGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right))
        var didStart = false
        var didHandoff = false
        var publishCount = 0
        var didSettle = false

        let turnTask = Task { @MainActor in
            await controller.commit(session) {
                defer { _ = controller.finish(session) }
                didStart = true
                await handoffGate.wait()
                didHandoff = true
                await publishGate.wait()
                publishCount += 1
                return true
            }
        }

        #expect(await waitUntil { didStart })
        turnTask.cancel()
        let settleTask = Task { @MainActor in
            await controller.settle(restore: { _ in })
            didSettle = true
        }

        handoffGate.open()
        #expect(await waitUntil { didHandoff })
        #expect(!didSettle)
        #expect(!controller.isIdle)

        publishGate.open()
        #expect(await turnTask.value)
        await settleTask.value

        #expect(publishCount == 1)
        #expect(didSettle)
        #expect(controller.isIdle)
    }

    @Test("a failed moving publish releases state and idle refresh gets a second chance")
    func failedPublishReleasesState() async throws {
        var movingPublishCount = 0
        var idleRefreshCount = 0
        let controller = EPUBPageTurnController {
            idleRefreshCount += 1
        }
        let session = try #require(controller.begin(to: .left))

        let result = await controller.commit(session) {
            defer { _ = controller.finish(session) }
            movingPublishCount += 1
            return false
        }

        #expect(!result)
        #expect(controller.isIdle)
        #expect(!controller.finish(session))

        await controller.settle(restore: { _ in })

        #expect(movingPublishCount == 1)
        #expect(idleRefreshCount == 1)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class Delegate: EPUBNavigatorDelegate {
    private(set) var presentationChangeCount = 0
    private(set) var locationChangeCount = 0
    private(set) var errorCount = 0

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationChangeCount += 1
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorCount += 1
    }

    func navigator(
        _ navigator: VisualNavigator,
        presentationDidChange presentation: VisualNavigatorPresentation
    ) {
        presentationChangeCount += 1
    }
}
