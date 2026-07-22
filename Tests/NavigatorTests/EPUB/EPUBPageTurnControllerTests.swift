//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

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

    @Test("production router exhaustively routes horizontal styles and bypasses continuous pagination")
    func productionRouter() async throws {
        let navigator = try makeNavigator()
        let options = NavigatorGoOptions(
            animated: true,
            otherOptions: ["probe": .string("preserved")]
        )
        let styles: [(EPUBPageTurnStyle, NavigatorGoOptions)] = [
            (.push, options),
            (.none, .none),
            (.simulation, .none),
            (.cover, .none),
        ]

        for (style, expectedOptions) in styles {
            navigator.pageTurnStyle = style
            var existingPathOptions: [NavigatorGoOptions] = []
            var pageTurnOptions: [NavigatorGoOptions] = []

            let result = await navigator.routePageTurn(
                to: .right,
                options: options,
                axis: .horizontalPaged,
                isReduceMotionEnabled: false,
                isVoiceOverRunning: false,
                usingExistingPath: { _, routedOptions in
                    existingPathOptions.append(routedOptions)
                    return true
                },
                usingPageTurn: { _, routedOptions in
                    pageTurnOptions.append(routedOptions)
                    return true
                }
            )

            #expect(result)
            #expect(existingPathOptions.isEmpty)
            #expect(pageTurnOptions == [expectedOptions])
        }

        for (style, _) in styles {
            navigator.pageTurnStyle = style
            var existingPathOptions: [NavigatorGoOptions] = []
            var pageTurnCount = 0

            let result = await navigator.routePageTurn(
                to: .left,
                options: options,
                axis: .verticalContinuous,
                isReduceMotionEnabled: false,
                isVoiceOverRunning: false,
                usingExistingPath: { _, routedOptions in
                    existingPathOptions.append(routedOptions)
                    return true
                },
                usingPageTurn: { _, _ in
                    pageTurnCount += 1
                    return true
                }
            )

            #expect(result)
            #expect(existingPathOptions == [options])
            #expect(pageTurnCount == 0)
        }
    }

    @Test("production location publisher calculates each time but notifies a successful locator once")
    func productionLocationPublisherDeduplicates() async throws {
        let oldLocation = makeLocator(href: "old.xhtml", progression: 0)
        let newLocation = makeLocator(href: "new.xhtml", progression: 0.5)
        let navigator = try makeNavigator(initialLocation: oldLocation)
        let delegate = Delegate()
        navigator.delegate = delegate
        var calculationCount = 0

        for _ in 0 ..< 2 {
            await navigator.publishCurrentLocation {
                calculationCount += 1
                return (newLocation, nil)
            }
        }

        #expect(calculationCount == 2)
        #expect(navigator.currentLocation == newLocation)
        #expect(delegate.locationChangeCount == 1)
        #expect(delegate.errorCount == 0)
    }

    @Test("real navigator go publishes once and pre-commit cancellation publishes nothing")
    func realNavigatorGoAndCancellation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator()

        delegate.resetLocationChanges()
        #expect(await navigator.goForward(options: .none))
        await navigator.settlePageTurn()
        #expect(delegate.locationChangeCount == 1)

        delegate.resetLocationChanges()
        let startGate = Gate()
        let cancelledTurn = Task { @MainActor in
            await startGate.wait()
            return await navigator.goBackward(options: .none)
        }
        cancelledTurn.cancel()
        startGate.open()

        let cancelledResult = await cancelledTurn.value
        #expect(!cancelledResult)
        await navigator.settlePageTurn()
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.errorCount == 0)
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

    @Test("settle restore owns the reversible session before commit can start")
    func settleRestoreCannotRaceCommit() async throws {
        let restoreGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right))
        var restoreStarted = false
        var commitStarted = false

        let settleTask = Task { @MainActor in
            await controller.settle { restoredSession in
                restoreStarted = true
                await restoreGate.wait()
                #expect(controller.finish(restoredSession))
            }
        }

        #expect(await waitUntil { restoreStarted })
        let committed = await controller.commit(session) {
            commitStarted = true
            return true
        }

        #expect(!committed)
        #expect(!commitStarted)

        restoreGate.open()
        await settleTask.value
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

    @Test("moving and coalesced idle location failures preserve the last locator and release all waiters")
    func productionLocationFailureReleasesWaiters() async throws {
        let lastLocation = makeLocator(href: "last-valid.xhtml", progression: 0.75)
        let navigator = try makeNavigator(initialLocation: lastLocation)
        let delegate = Delegate()
        navigator.delegate = delegate
        let idleCalculationGate = Gate()
        var calculationCount = 0
        var settledCount = 0

        let calculate: () async -> (Locator?, NavigatorViewport?) = {
            calculationCount += 1
            if calculationCount == 2 {
                await idleCalculationGate.wait()
            }
            return (nil, nil)
        }
        let requestRefresh = {
            _ = Task { @MainActor in
                await navigator.performCurrentLocationRefresh(calculating: calculate)
            }
        }
        let controller = EPUBPageTurnController {
            await navigator.awaitCurrentLocationRefresh(request: requestRefresh)
        }
        let session = try #require(controller.begin(to: .right))

        let moved = await controller.commit(session) {
            defer { _ = controller.finish(session) }
            await navigator.publishCurrentLocation(calculating: calculate)
            return true
        }
        #expect(moved)

        let firstSettle = Task { @MainActor in
            await controller.settle(restore: { _ in })
            settledCount += 1
        }
        let secondSettle = Task { @MainActor in
            await controller.settle(restore: { _ in })
            settledCount += 1
        }

        #expect(await waitUntil { calculationCount == 2 })
        #expect(settledCount == 0)
        idleCalculationGate.open()
        await firstSettle.value
        await secondSettle.value

        #expect(calculationCount == 2)
        #expect(settledCount == 2)
        #expect(controller.isIdle)
        #expect(navigator.currentLocation == lastLocation)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.errorCount == 0)
    }

    private func makeNavigator(
        initialLocation: Locator? = nil,
        config: EPUBNavigatorViewController.Configuration = .init()
    ) throws -> EPUBNavigatorViewController {
        try EPUBNavigatorViewController(
            publication: Publication(
                manifest: Manifest(metadata: Metadata(title: "Test"))
            ),
            initialLocation: initialLocation,
            config: config
        )
    }

    private func makeLoadedNavigator() async throws -> (EPUBNavigatorViewController, Delegate) {
        let readingOrder = [
            Link(href: "chapter-1.xhtml", mediaType: .xhtml),
            Link(href: "chapter-2.xhtml", mediaType: .xhtml),
        ]
        let containers: [Container] = readingOrder.map { link in
            SingleResourceContainer(
                resource: DataResource(string: "<html><body><p>Page</p></body></html>"),
                at: link.url()
            )
        }
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test"),
                readingOrder: readingOrder
            ),
            container: CompositeContainer(containers)
        )
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: makeLocator(href: "chapter-1.xhtml", progression: 0),
            config: .init(pageTurnStyle: .push)
        )
        let delegate = Delegate()
        navigator.delegate = delegate
        navigator.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        navigator.loadViewIfNeeded()
        await navigator.initialized()

        for _ in 0 ..< 100 where delegate.locationChangeCount == 0 {
            await navigator.settlePageTurn()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(delegate.locationChangeCount == 1)
        return (navigator, delegate)
    }

    private func makeLocator(href: String, progression: Double) -> Locator {
        Locator(
            href: AnyURL(string: href)!,
            mediaType: .xhtml,
            locations: .init(progression: progression)
        )
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

    func resetLocationChanges() {
        locationChangeCount = 0
    }
}
