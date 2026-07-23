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

    @Test("capture-time page turn style assignments are last-wins even when returning to the applied value")
    func captureTimePageTurnStyleIsLastWins() async throws {
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Test"))
        )
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: nil,
            config: .init(pageTurnStyle: .push)
        )
        let pagination = NSObject()
        let spread = NSObject()
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: pagination,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        var didStartCapture = false
        var canFinishCapture = false
        let captureTask = Task {
            try? await navigator.snapshotProvider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    didStartCapture = true
                    while !canFinishCapture {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                    return UIImage()
                },
                restore: {}
            )
        }
        #expect(await waitUntil { didStartCapture })

        navigator.pageTurnStyle = .none
        navigator.pageTurnStyle = .push
        canFinishCapture = true
        _ = await captureTask.value

        #expect(navigator.pageTurnStyle == .push)
        #expect(navigator.snapshotProvider.isIdle)
    }

    @Test("pending ViewModel pagination invalidation can be flushed synchronously")
    func viewModelPaginationInvalidationFlushesSynchronously() async {
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Test"))
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: [],
            config: .init()
        )
        let delegate = ViewModelDelegate()
        viewModel.delegate = delegate

        viewModel.submitPreferences(EPUBPreferences(scroll: true))
        #expect(delegate.invalidationCount == 0)

        viewModel.flushPendingPaginationInvalidation()
        #expect(delegate.invalidationCount == 1)
        await nextMainRunLoop()
        #expect(delegate.invalidationCount == 1)
    }

    @Test("pagination replacement waits for snapshot restore and drains before settle")
    func paginationReplacementUsesSnapshotBarrier() async throws {
        let navigator = try await makeMountedNavigator(
            layout: .reflowable,
            pageTurnStyle: .push
        )
        let originalPagination = try #require(currentPaginationView(in: navigator))
        let originalSpread = try #require(originalPagination.currentView as? EPUBSpreadView)
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: originalPagination,
            spread: originalSpread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let restoreGate = Gate()
        var didEnterRestore = false
        let captureTask = Task {
            try await navigator.snapshotProvider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: { UIImage() },
                restore: {
                    didEnterRestore = true
                    await restoreGate.wait()
                }
            )
        }
        #expect(await waitUntil { didEnterRestore })

        navigator.submitPreferences(EPUBPreferences(scroll: true))
        #expect(currentPaginationView(in: navigator) === originalPagination)

        var didSettle = false
        let settleTask = Task {
            await navigator.snapshotProvider.settle()
            didSettle = true
        }
        await Task.yield()
        #expect(!didSettle)

        restoreGate.open()
        #expect(try await captureTask.value == nil)
        await settleTask.value

        #expect(didSettle)
        #expect(currentPaginationView(in: navigator)?.axis == .verticalContinuous)
        #expect(currentPaginationView(in: navigator) !== originalPagination)
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

    @Test("none pan maps horizontal swipes in LTR and RTL")
    func nonePanDirection() {
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: -1, y: 0),
            readingProgression: .ltr
        ) == .right)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: 1, y: 0),
            readingProgression: .ltr
        ) == .left)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: -1, y: 0),
            readingProgression: .rtl
        ) == .left)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: 1, y: 0),
            readingProgression: .rtl
        ) == .right)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: 10, y: 11),
            readingProgression: .ltr
        ) == nil)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: 120, y: 100),
            readingProgression: .ltr
        ) == nil)
        #expect(EPUBPageTurnInteraction.direction(
            for: CGPoint(x: -121, y: 100),
            readingProgression: .ltr
        ) == .right)
    }

    @Test("interactive pointer IDs clear after target changes and remain isolated")
    func interactivePointerPolicy() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBSpreadView)

        spreadView.updateInteractivePointerState(from: [
            "pointerId": 1, "phase": "down", "interactiveElement": "<a>",
        ])
        spreadView.updateInteractivePointerState(from: [
            "pointerId": 2, "phase": "down", "interactiveElement": "<video>",
        ])
        #expect(spreadView.hasActiveInteractivePointer)

        spreadView.updateInteractivePointerState(from: [
            "pointerId": 1, "phase": "move",
        ])
        spreadView.updateInteractivePointerState(from: [
            "pointerId": 1, "phase": "up",
        ])
        #expect(spreadView.hasActiveInteractivePointer)

        spreadView.updateInteractivePointerState(from: [
            "pointerId": 2, "phase": "cancel",
        ])
        #expect(!spreadView.hasActiveInteractivePointer)
    }

    @Test("none pan commits at the exact distance or velocity threshold")
    func nonePanThresholds() {
        let session = PageTurnSession(direction: .left, readingProgression: .ltr)
        #expect(!EPUBPageTurnInteraction.shouldCommit(
            translationX: 21.9,
            viewportWidth: 100,
            velocityX: 0,
            session: session
        ))
        #expect(EPUBPageTurnInteraction.shouldCommit(
            translationX: 22,
            viewportWidth: 100,
            velocityX: 0,
            session: session
        ))
        #expect(!EPUBPageTurnInteraction.shouldCommit(
            translationX: 0,
            viewportWidth: 100,
            velocityX: 649,
            session: session
        ))
        #expect(EPUBPageTurnInteraction.shouldCommit(
            translationX: 0,
            viewportWidth: 100,
            velocityX: 650,
            session: session
        ))
    }

    @Test("none pan never commits after reversing away from its LTR or RTL session direction")
    func nonePanReverseDirection() {
        let cases: [(ReadiumNavigator.ReadingProgression, EPUBSpreadView.Direction, CGFloat)] = [
            (.ltr, .right, 1),
            (.ltr, .left, -1),
            (.rtl, .right, -1),
            (.rtl, .left, 1),
        ]

        for (readingProgression, direction, reverseSign) in cases {
            let session = PageTurnSession(
                direction: direction,
                readingProgression: readingProgression
            )
            #expect(!EPUBPageTurnInteraction.shouldCommit(
                translationX: reverseSign * 22,
                viewportWidth: 100,
                velocityX: reverseSign * 650,
                session: session
            ))
        }
    }

    @Test("none session keeps its begin reading progression while the setting changes")
    func noneSessionSnapshotsReadingProgression() throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var readingProgression = ReadiumNavigator.ReadingProgression.ltr
        let session = try #require(controller.begin(
            to: .right,
            readingProgression: readingProgression
        ))

        readingProgression = .rtl
        let progress = try #require(controller.track(
            session,
            translationX: -22,
            viewportWidth: 100
        ))

        #expect(readingProgression == .rtl)
        #expect(session.readingProgression == .ltr)
        #expect(abs(progress - 0.22) < 0.0001)
        #expect(EPUBPageTurnInteraction.shouldCommit(
            translationX: -22,
            viewportWidth: 100,
            velocityX: -650,
            session: session
        ))
    }

    @Test("none cross-resource handoff keeps the session reading progression")
    func noneCrossResourceHandoffSnapshotsReadingProgression() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )

        navigator.submitPreferences(EPUBPreferences(readingProgression: .rtl))
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -100,
            velocityX: -700
        )

        #expect(await waitUntil {
            self.currentPaginationView(in: navigator)?.currentIndex == 1
        })
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
    }

    @Test("none changed handler tracks without moving the mounted pagination or spread")
    func nonePanTrackingDoesNotMoveView() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBSpreadView)
        let outerScrollView = try #require(
            paginationView.subviews.compactMap { $0 as? UIScrollView }.first
        )
        let baseline = [paginationView, outerScrollView, spreadView, spreadView.scrollView]
            .map { ($0.frame, $0.transform) }
        let offsets = [outerScrollView.contentOffset, spreadView.scrollView.contentOffset]

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -100
        )

        let current = [paginationView, outerScrollView, spreadView, spreadView.scrollView]
            .map { ($0.frame, $0.transform) }
        #expect(current.elementsEqual(baseline, by: ==))
        #expect(outerScrollView.contentOffset == offsets[0])
        #expect(spreadView.scrollView.contentOffset == offsets[1])

        navigator.handlePageTurnPanForTesting(
            state: .cancelled,
            translationX: 0,
            velocityX: 0
        )
    }

    @Test("none should-begin judgment has no navigation side effects")
    func nonePanShouldBeginIsSideEffectFree() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        let paginationView = try #require(currentPaginationView(in: navigator))

        #expect(paginationView.isUserInteractionEnabled)
        #expect(navigator.canBeginPageTurnPanForTesting())
        #expect(paginationView.isUserInteractionEnabled)
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        #expect(!navigator.isPageTurnIdleForTesting)

        navigator.handlePageTurnPanForTesting(
            state: .cancelled,
            translationX: 0,
            velocityX: 0
        )
    }

    @Test("none pan begins only after recognition and permits a second swipe")
    func nonePanPermitsConsecutiveSwipes() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)

        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: -700)
        navigator.handlePageTurnPanForTesting(state: .ended, translationX: -100, velocityX: -700)

        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 1
        })
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))

        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: 700)
        navigator.handlePageTurnPanForTesting(state: .ended, translationX: 100, velocityX: 700)

        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 0
        })
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
    }

    @Test("animated pan keeps preparation ownership when end reenters during surface capture")
    func animatedPanEndDuringSurfaceCaptureRetainsPreparation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .push)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        root.onSnapshot = {
            root.onSnapshot = nil
            navigator.handlePageTurnPanForTesting(
                state: .ended,
                translationX: -100,
                velocityX: -700
            )
        }
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )

        #expect(await waitUntil {
            self.currentPaginationView(in: navigator)?.currentIndex == 1
        })
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("animated pan serializes a cold chapter seam and its immediate reverse")
    func animatedPanSerializesColdChapterSeamAndReverse() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .push)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        #expect(navigator.armColdForwardPageTurnTargetForTesting())

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -100,
            velocityX: -700
        )
        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 1
        })
        await navigator.settlePageTurn()

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: 700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: 100,
            velocityX: 700
        )
        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 0
        })
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("accessibility cancellation before preparation publishes no target")
    func accessibilityCancellationBeforePreparationPublishesNothing() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .push,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -100,
            velocityX: -700
        )
        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("mounted navigator keeps one transaction recognizer across push none and cover")
    func mountedRuntimeInteractionPolicy() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .push)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBSpreadView)
        let outerScrollView = try #require(
            paginationView.subviews.compactMap { $0 as? UIScrollView }.first
        )

        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
        let pushPans = rootPanRecognizers(in: navigator)
        #expect(pushPans.count == 1)
        let transactionPan = try #require(pushPans.first)
        #expect(transactionPan.delegate === navigator)
        #expect(transactionPan.maximumNumberOfTouches == 1)

        navigator.pageTurnStyle = .none
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
        let nonePans = rootPanRecognizers(in: navigator)
        #expect(nonePans.count == 1)
        #expect(nonePans.first === transactionPan)

        navigator.pageTurnStyle = .simulation
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).isEmpty)
        #expect(transactionPan.view == nil)

        navigator.pageTurnStyle = .cover
        #expect(rootPanRecognizers(in: navigator).first === transactionPan)

        navigator.pageTurnStyle = .push
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).first === transactionPan)
    }

    @Test("none reapplies native pan policy after current and preloaded WebViews finish navigation")
    func noneReappliesNativePanPolicyAfterWebNavigation() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .push)
        let paginationView = try #require(currentPaginationView(in: navigator))

        navigator.pageTurnStyle = .none
        let currentSpread = try #require(paginationView.currentView as? EPUBSpreadView)
        let preloadedSpread = try #require(
            navigator.paginationView(paginationView, pageViewAtIndex: 1) as? EPUBSpreadView
        )
        let spreadViews = [currentSpread, preloadedSpread]

        for spreadView in spreadViews {
            spreadView.scrollView.panGestureRecognizer.isEnabled = true

            spreadView.webView(spreadView.webView, didFinish: nil)

            #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
        }
    }

    @Test("fixed WebView navigation reapplies none pan policy without blocking zoomed content pan")
    func fixedReappliesNativePanPolicyAfterWebNavigation() async throws {
        let navigator = try await makeMountedNavigator(layout: .fixed, pageTurnStyle: .none)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBFixedSpreadView)
        spreadView.scrollView.minimumZoomScale = 1
        spreadView.scrollView.maximumZoomScale = 3

        spreadView.scrollView.zoomScale = 1
        spreadView.scrollView.panGestureRecognizer.isEnabled = true
        spreadView.webView(spreadView.webView, didFinish: nil)
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)

        spreadView.scrollView.zoomScale = 2
        spreadView.scrollView.panGestureRecognizer.isEnabled = false
        spreadView.webView(spreadView.webView, didFinish: nil)
        #expect(spreadView.scrollView.panGestureRecognizer.isEnabled)
    }

    @Test("accessibility notifications downgrade and restore the user's page turn style")
    func accessibilityNotificationsReconfigureMountedNavigator() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let navigator = try await makeMountedNavigator(
            pageTurnStyle: .push,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let paginationView = try #require(currentPaginationView(in: navigator))
        let outerScrollView = try #require(
            paginationView.subviews.compactMap { $0 as? UIScrollView }.first
        )

        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).count == 1)

        status.isReduceMotionEnabled = true
        await postFromBackground(
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            to: notificationCenter
        )
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).count == 1)
        #expect(status.wereAllReadsOnMainThread)

        status.isReduceMotionEnabled = false
        status.isVoiceOverRunning = true
        await postFromBackground(
            UIAccessibility.voiceOverStatusDidChangeNotification,
            to: notificationCenter
        )
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).count == 1)
        #expect(status.wereAllReadsOnMainThread)

        status.isVoiceOverRunning = false
        await postFromBackground(
            UIAccessibility.voiceOverStatusDidChangeNotification,
            to: notificationCenter
        )
        #expect(!outerScrollView.panGestureRecognizer.isEnabled)
        #expect(rootPanRecognizers(in: navigator).count == 1)
        #expect(status.wereAllReadsOnMainThread)

        navigator.pageTurnStyle = .simulation
        #expect(rootPanRecognizers(in: navigator).isEmpty)
    }

    @Test("accessibility changes cancel pre-commit sessions and reject late commits")
    func accessibilityChangeCancelsPreCommitSession() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var commitCount = 0

        #expect(controller.invalidatePreCommitSession()?.id == session.id)
        let committed = await controller.commit(session) {
            commitCount += 1
            return true
        }

        #expect(!committed)
        #expect(commitCount == 0)
        #expect(controller.isIdle)
    }

    @Test("accessibility changes let post-commit sessions finish")
    func accessibilityChangeFinishesPostCommitSession() async throws {
        let commitGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var commitCount = 0

        let task = Task { @MainActor in
            await controller.commit(session) {
                defer { _ = controller.finish(session) }
                commitCount += 1
                await commitGate.wait()
                return true
            }
        }

        #expect(await waitUntil { commitCount == 1 })
        #expect(controller.invalidatePreCommitSession() == nil)
        #expect(!controller.isIdle)

        commitGate.open()
        #expect(await task.value)
        #expect(commitCount == 1)
        #expect(controller.isIdle)
    }

    @Test("accessibility invalidation does not finish an in-flight restore")
    func accessibilityChangeWaitsForRestore() async throws {
        let restoreGate = Gate()
        var refreshCount = 0
        var restoreStarted = false
        var settleFinished = false
        var restoreSession: PageTurnSession?
        let controller = EPUBPageTurnController {
            refreshCount += 1
        }
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))

        let settleTask = Task { @MainActor in
            await controller.settle { restoringSession in
                restoreSession = restoringSession
                restoreStarted = true
                await restoreGate.wait()
                _ = controller.finish(restoringSession)
            }
            settleFinished = true
        }

        #expect(await waitUntil { restoreStarted })
        #expect(controller.invalidatePreCommitSession() == nil)
        #expect(!controller.isIdle)
        await Task.yield()
        #expect(!settleFinished)
        #expect(refreshCount == 0)

        var lateCommitCount = 0
        let committed = await controller.commit(session) {
            lateCommitCount += 1
            return true
        }
        #expect(!committed)
        #expect(lateCommitCount == 0)

        restoreGate.open()
        await settleTask.value
        #expect(restoreSession?.id == session.id)
        #expect(settleFinished)
        #expect(refreshCount == 1)
        #expect(controller.isIdle)
    }

    @Test("accessibility observers do not retain the navigator after deinit")
    func accessibilityObserversReleaseNavigator() async throws {
        let notificationCenter = ObserverRemovalTrackingNotificationCenter()
        let status = AccessibilityStatusBox()
        weak var weakNavigator: EPUBNavigatorViewController?

        do {
            let navigator = try makeNavigator(
                notificationCenter: notificationCenter,
                accessibilityStatus: status
            )
            weakNavigator = navigator
        }

        #expect(await waitUntil { weakNavigator == nil })
        #expect(notificationCenter.removeObserverCount == 3)
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        #expect(weakNavigator == nil)
    }

    @Test("mounted zoom and style changes release none sessions safely")
    func mountedZoomAndStyleReconfiguration() async throws {
        let fixedNavigator = try await makeMountedNavigator(
            layout: .fixed,
            pageTurnStyle: .none
        )
        let fixedPagination = try #require(currentPaginationView(in: fixedNavigator))
        let fixedSpread = try #require(fixedPagination.currentView as? EPUBFixedSpreadView)
        fixedSpread.scrollView.minimumZoomScale = 1
        fixedSpread.scrollView.maximumZoomScale = 3
        fixedSpread.scrollView.zoomScale = 2
        fixedSpread.scrollViewDidZoom(fixedSpread.scrollView)
        #expect(!fixedSpread.allowsPageTurn)
        #expect(fixedSpread.scrollView.panGestureRecognizer.isEnabled)

        fixedSpread.scrollView.zoomScale = 1
        fixedSpread.scrollViewDidZoom(fixedSpread.scrollView)
        #expect(fixedSpread.allowsPageTurn)
        #expect(!fixedSpread.scrollView.panGestureRecognizer.isEnabled)

        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: -700)
        navigator.pageTurnStyle = .simulation
        navigator.pageTurnStyle = .none
        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: -700)
        #expect(!navigator.isPageTurnIdleForTesting)
        navigator.handlePageTurnPanForTesting(state: .cancelled, translationX: 0, velocityX: 0)
    }

    @Test("submitPreferences replaces the current pagination and releases the none session")
    func mountedAxisReplacementReleasesNoneSession() async throws {
        let navigator = try await makeMountedNavigator(
            layout: .reflowable,
            pageTurnStyle: .none
        )
        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: -700)
        navigator.submitPreferences(EPUBPreferences(scroll: true))

        #expect(await waitUntil {
            guard let paginationView = self.currentPaginationView(in: navigator) else {
                return false
            }
            return paginationView.axis == .verticalContinuous
                && paginationView.currentView != nil
        })
        let replacement = try #require(currentPaginationView(in: navigator))
        #expect(replacement.axis == .verticalContinuous)
        #expect(rootPanRecognizers(in: navigator).isEmpty)

        let spreadView = try #require(replacement.currentView as? EPUBSpreadView)
        navigator.spreadView(
            spreadView,
            didFailToLoadResourceAt: try #require(RelativeURL(path: "chapter.xhtml")),
            withError: .decoding("Expected test rollback")
        )

        #expect(currentPaginationView(in: navigator)?.axis == .horizontalPaged)
        #expect(rootPanRecognizers(in: navigator).count == 1)
        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: 700)
        #expect(!navigator.isPageTurnIdleForTesting)
        navigator.handlePageTurnPanForTesting(state: .cancelled, translationX: 0, velocityX: 0)
    }

    @Test("push none and cover disable native paging for the shared transaction")
    func nativePanPolicy() {
        for style in [EPUBPageTurnStyle.push, .none, .cover] {
            let policy = EPUBPageTurnInteraction.policy(
                axis: .horizontalPaged,
                style: style
            )
            #expect(!policy.allowsNativeHorizontalPaging)
        }

        let continuous = EPUBPageTurnInteraction.policy(
            axis: .verticalContinuous,
            style: .none
        )
        #expect(continuous.allowsNativeHorizontalPaging)
    }

    @Test("page-turn surfaces are generic marked views over the full delegate reader root")
    func coverUsesFullReaderSurfaceHost() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let topChrome = UILabel(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        topChrome.text = "TOP-SURFACE-PROBE"
        let documentFrame = CGRect(x: 0, y: 64, width: 390, height: 736)
        let bottomChrome = UILabel(frame: CGRect(x: 0, y: 800, width: 390, height: 44))
        bottomChrome.text = "BOTTOM-SURFACE-PROBE"
        navigator.view.frame = documentFrame
        root.addSubview(topChrome)
        root.addSubview(navigator.view)
        root.addSubview(bottomChrome)
        container.addSubview(root)

        let delegate = Delegate()
        delegate.pageTurnRootView = root
        navigator.delegate = delegate

        #expect(navigator.beginCoverPageTurnForTesting(to: .right))
        #expect(await waitUntil { pageTurnSurfaces(in: container).count == 2 })
        let surfaces = pageTurnSurfaces(in: container)
        #expect(surfaces.count == 2)
        #expect(Set(surfaces.compactMap(\.accessibilityIdentifier)) == Set([
            "readium.page-turn.surface.current",
            "readium.page-turn.surface.target",
        ]))
        #expect(surfaces.allSatisfy { $0.frame == root.frame })
        #expect(surfaces.allSatisfy { $0.frame.contains(topChrome.convert(topChrome.bounds, to: container)) })
        #expect(surfaces.allSatisfy { $0.frame.contains(navigator.view.convert(navigator.view.bounds, to: container)) })
        #expect(surfaces.allSatisfy { $0.frame.contains(bottomChrome.convert(bottomChrome.bounds, to: container)) })

        await navigator.settlePageTurn()
    }

    @Test("current and target snapshots share the synchronous install guard")
    func targetSnapshotUsesInstallGuard() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        let delegate = Delegate()
        delegate.pageTurnRootView = root
        navigator.delegate = delegate
        var protectedSnapshots = 0
        root.onSnapshot = {
            if navigator.isInstallingPageTurnSurfaceForTesting {
                protectedSnapshots += 1
            }
        }

        #expect(navigator.beginCoverPageTurnForTesting(to: .right))
        #expect(root.snapshotCount == 2)
        #expect(protectedSnapshots == 2)
        await navigator.settlePageTurn()
    }

    @Test("changing style restores and removes an active whole-reader transaction")
    func styleChangeCancelsWholeReaderTransaction() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        let delegate = Delegate()
        delegate.pageTurnRootView = root
        navigator.delegate = delegate

        #expect(navigator.beginCoverPageTurnForTesting(to: .right))
        #expect(pageTurnSurfaces(in: container).count == 2)
        navigator.pageTurnStyle = .push
        await navigator.settlePageTurn()

        #expect(navigator.pageTurnStyle == .push)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("stalled preparation does not retain the navigator and deinit cancels it")
    func stalledPreparationReleasesNavigatorAndSurface() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: container.bounds)
        container.addSubview(root)
        let navigationGate = Gate()
        let navigationStarted = ThreadSafeFlag()
        let cancellation = ThreadSafeFlag()
        var navigator: EPUBNavigatorViewController? = try await makeMountedNavigator(
            pageTurnStyle: .cover
        )
        navigator?.view.frame = root.bounds
        root.addSubview(try #require(navigator?.view))
        let delegate = Delegate()
        delegate.pageTurnRootView = root
        navigator?.delegate = delegate
        navigator?.pageTurnNavigationForTesting = { _, _ in
            navigationStarted.set()
            return await withTaskCancellationHandler {
                await navigationGate.wait()
                return false
            } onCancel: {
                cancellation.set()
            }
        }
        #expect(navigator?.beginPreparingPageTurnForTesting(to: .right) == true)
        #expect(await waitUntil { navigationStarted.value })
        #expect(pageTurnSurfaces(in: container).count == 1)
        weak let releasedNavigator = navigator

        navigator = nil

        #expect(await waitUntil { releasedNavigator == nil })
        #expect(await waitUntil { cancellation.value })
        #expect(await waitUntil { pageTurnSurfaces(in: container).isEmpty })
        navigationGate.open()
    }

    @Test("cover with animated false uses the instant transaction without surfaces")
    func coverAnimatedFalseIsInstant() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        #expect(await navigator.goForward(options: .none))
        await navigator.settlePageTurn()

        #expect(root.snapshotCount == 0)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
    }

    @Test("programmatic chapter targets use whole-reader push and cover transactions")
    func programmaticChapterTargetsUsePageTurnSurfaces() async throws {
        for style in [EPUBPageTurnStyle.push, .cover] {
            let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: style)
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let root = SnapshotObservingView(frame: container.bounds)
            navigator.view.frame = root.bounds
            root.addSubview(navigator.view)
            container.addSubview(root)
            delegate.pageTurnRootView = root
            delegate.resetLocationChanges()
            let link = try #require(navigator.publication.readingOrder.dropFirst().first)
            let target = try #require(await navigator.publication.locate(link))
            let options = NavigatorGoOptions(
                animated: true,
                otherOptions: [
                    "readium.epub.pageTurnDirection": .string("forward")
                ]
            )

            let turn = Task { @MainActor in
                await navigator.go(to: target, options: options)
            }
            #expect(await waitUntil { !pageTurnSurfaces(in: container).isEmpty })
            #expect(await turn.value)
            await navigator.settlePageTurn()

            #expect(navigator.currentLocation?.href.isEquivalentTo(target.href) == true)
            #expect(delegate.locationChangeCount == 1)
            #expect(root.snapshotCount >= 2)
            #expect(pageTurnSurfaces(in: container).isEmpty)
        }
    }

    @Test("an identity recapture failure after commit never publishes or exposes a stale target")
    func committedIdentityFailureReleasesSurface() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()

        let turn = Task { @MainActor in
            await navigator.goForward(options: .animated)
        }
        #expect(await waitUntil { navigator.isPageTurnCommittingForTesting })
        navigator.view.frame.origin.y = 1
        root.shouldFailSnapshots = true

        #expect(!(await turn.value))
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(delegate.locationChangeCount == 0)
        #expect(!pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnControllerIdleForTesting)
    }

    @Test("cover swipe is not gated by an unrelated body snapshot capture")
    func coverCrossResourceIgnoresBodySnapshotCapture() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spread = try #require(paginationView.currentView as? EPUBSpreadView)
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: paginationView,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let captureGate = Gate()
        let capture = Task { @MainActor in
            try? await navigator.snapshotProvider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    await captureGate.wait()
                    return UIImage()
                },
                restore: {}
            )
        }

        #expect(await waitUntil { !navigator.isPageTurnSnapshotInputEnabledForTesting })
        #expect(navigator.canBeginPageTurnPanForTesting())
        captureGate.open()
        _ = await capture.value
    }

    @Test("cold cross-resource cover unloads, navigates, then captures a new target resource")
    func coldCrossResourceCoverStartsWithoutLoadedTarget() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        let paginationView = try #require(currentPaginationView(in: navigator))
        #expect(navigator.armColdForwardPageTurnTargetForTesting())
        #expect(paginationView.loadedViews[1] == nil)
        #expect(navigator.pageTurnSurfaceTransactionEvidenceForTesting.isCold)

        #expect(await navigator.goForward(options: .animated))
        await navigator.settlePageTurn()

        let evidence = navigator.pageTurnSurfaceTransactionEvidenceForTesting
        #expect(evidence.didBeginWithColdTarget)
        #expect(evidence.didNavigateColdTarget)
        #expect(evidence.didCaptureAfterColdNavigation)
        #expect(paginationView.currentIndex == 1)
        #expect(paginationView.loadedViews[1] != nil)
    }

    @Test("fixed zoom preserves content pan and blocks page turns until minimum zoom")
    func fixedZoomPolicy() {
        #expect(EPUBFixedSpreadView.allowsContentPan(
            allowsNativeHorizontalPaging: false,
            zoomScale: 2,
            minimumZoomScale: 1
        ))
        #expect(!EPUBFixedSpreadView.allowsPageTurn(
            zoomScale: 2,
            minimumZoomScale: 1
        ))
        #expect(!EPUBFixedSpreadView.allowsContentPan(
            allowsNativeHorizontalPaging: false,
            zoomScale: 1,
            minimumZoomScale: 1
        ))
        #expect(EPUBFixedSpreadView.allowsPageTurn(
            zoomScale: 1,
            minimumZoomScale: 1
        ))
    }

    @Test("whole-reader cover keeps its target still in both physical directions")
    func coverGeometry() {
        for direction in [EPUBSpreadView.Direction.left, .right] {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
            let root = UIView(frame: container.bounds)
            container.addSubview(root)
            let animator = EPUBPageTurnSurfaceAnimator(
                rootView: root,
                style: .cover,
                physicalCompletionDirection: direction
            )
            #expect(animator != nil)
            #expect(animator?.captureTarget() == true)
            animator?.render(progress: 0.5)

            let current = pageTurnSurfaces(in: container).first {
                $0.accessibilityIdentifier == "readium.page-turn.surface.current"
            }
            let target = pageTurnSurfaces(in: container).first {
                $0.accessibilityIdentifier == "readium.page-turn.surface.target"
            }
            let expectedCurrentX: CGFloat = direction == .left ? -100 : 100
            #expect(current?.transform.tx == expectedCurrentX)
            #expect(target?.transform == .identity)
            animator?.remove()
        }
    }

    @Test("target surface identity is invalidated when the document frame changes")
    func targetSurfaceIdentityTracksLiveReaderGeometry() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let root = UIView(frame: container.bounds)
        let document = UIView(frame: CGRect(x: 0, y: 64, width: 200, height: 292))
        container.addSubview(root)
        root.addSubview(document)
        let animator = EPUBPageTurnSurfaceAnimator(
            rootView: root,
            documentView: document,
            style: .cover,
            physicalCompletionDirection: .left
        )

        #expect(animator?.captureTarget() == true)
        #expect(animator?.hasMatchingTargetRootIdentity == true)
        document.frame.origin.y = 80
        #expect(animator?.hasMatchingTargetRootIdentity == false)
        #expect(animator?.recaptureTarget() == true)
        #expect(animator?.hasMatchingTargetRootIdentity == true)
        animator?.remove()
    }

    @Test("root identity detects same-sized replacement and frame-origin changes")
    func rootIdentityTracksActualReaderRoot() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 420))
        let firstRoot = SnapshotObservingView(frame: CGRect(x: 8, y: 10, width: 200, height: 400))
        let secondRoot = SnapshotObservingView(frame: firstRoot.frame)
        let document = UIView(frame: CGRect(x: 0, y: 64, width: 200, height: 292))
        firstRoot.addSubview(document)
        container.addSubview(firstRoot)
        var activeRoot: UIView = firstRoot
        let animator = try #require(EPUBPageTurnSurfaceAnimator(
            rootViewProvider: { activeRoot },
            documentView: document,
            style: .cover,
            physicalCompletionDirection: .left
        ))

        #expect(animator.captureTarget())
        activeRoot = secondRoot
        secondRoot.addSubview(document)
        container.addSubview(secondRoot)
        #expect(!animator.hasMatchingCurrentRootIdentity)
        #expect(!animator.hasMatchingTargetRootIdentity)
        #expect(animator.recaptureCurrent())
        #expect(animator.recaptureTarget())
        #expect(animator.hasMatchingCurrentRootIdentity)
        #expect(animator.hasMatchingTargetRootIdentity)
        #expect(pageTurnSurfaces(in: container).allSatisfy {
            $0.superview === container && $0.frame == secondRoot.frame
        })

        secondRoot.frame.origin = CGPoint(x: 18, y: 24)
        #expect(!animator.hasMatchingCurrentRootIdentity)
        #expect(!animator.hasMatchingTargetRootIdentity)
        animator.remove()
    }

    @Test("current surface identity is refreshed before exposing a changed reader root")
    func currentSurfaceIdentityTracksLiveReaderGeometry() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let root = SnapshotObservingView(frame: container.bounds)
        let document = UIView(frame: CGRect(x: 0, y: 64, width: 200, height: 292))
        container.addSubview(root)
        root.addSubview(document)
        let animator = EPUBPageTurnSurfaceAnimator(
            rootView: root,
            documentView: document,
            style: .cover,
            physicalCompletionDirection: .left
        )

        #expect(animator?.hasMatchingCurrentRootIdentity == true)
        document.frame.origin.y = 80
        #expect(animator?.hasMatchingCurrentRootIdentity == false)
        #expect(animator?.recaptureCurrent() == true)
        #expect(animator?.hasMatchingCurrentRootIdentity == true)
        #expect(root.snapshotCount == 2)
        animator?.remove()
    }

    @Test("cover production mapping mirrors programmatic and gesture turns in RTL")
    func coverProductionDirectionMapping() {
        let cases: [(
            readingProgression: ReadiumNavigator.ReadingProgression,
            direction: EPUBSpreadView.Direction,
            velocityX: CGFloat,
            translationX: CGFloat,
            isForward: Bool,
            physicalDirection: EPUBSpreadView.Direction
        )] = [
            (.ltr, .right, -700, -50, true, .left),
            (.ltr, .left, 700, 50, false, .right),
            (.rtl, .left, 700, 50, true, .right),
            (.rtl, .right, -700, -50, false, .left),
        ]

        for testCase in cases {
            let session = PageTurnSession(
                direction: testCase.direction,
                readingProgression: testCase.readingProgression
            )
            #expect(session.isForward == testCase.isForward)
            #expect(session.physicalCompletionDirection == testCase.physicalDirection)
            #expect(EPUBPageTurnInteraction.coverDirection(
                for: CGPoint(x: testCase.velocityX, y: 0)
            ) == testCase.direction)
            #expect(EPUBPageTurnInteraction.coverProgress(
                translationX: testCase.translationX,
                viewportWidth: 100,
                session: session
            ) == 0.5)
            #expect(EPUBPageTurnInteraction.coverShouldCommit(
                translationX: testCase.translationX,
                viewportWidth: 100,
                velocityX: testCase.velocityX,
                session: session
            ))
        }

        #expect(EPUBPageTurnInteraction.coverDirection(
            for: CGPoint(x: -120, y: 100)
        ) == nil)
        #expect(EPUBPageTurnInteraction.coverDirection(
            for: CGPoint(x: 121, y: 100)
        ) == .left)
    }

    @Test("settle waits for an irreversible commit and its single location publish")
    func settleWaitsForProgrammaticCommit() async throws {
        let commitGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var commitCount = 0
        var publishCount = 0
        var restoreCount = 0
        var didSettle = false

        let commit = Task { @MainActor in
            await controller.commit(session) {
                commitCount += 1
                await commitGate.wait()
                publishCount += 1
                #expect(controller.finish(session))
                return true
            }
        }
        #expect(await waitUntil { commitCount == 1 })

        let settle = Task { @MainActor in
            await controller.settle { _ in restoreCount += 1 }
            didSettle = true
        }
        await Task.yield()
        #expect(!didSettle)
        #expect(restoreCount == 0)
        #expect(publishCount == 0)

        commitGate.open()
        #expect(await commit.value)
        await settle.value
        #expect(publishCount == 1)
        #expect(restoreCount == 0)
        #expect(didSettle)
        #expect(controller.isIdle)
    }

    @Test("failed inverse restore deterministically falls back to the original locator")
    func failedInverseUsesOriginalLocation() async {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var inverseCount = 0
        var originalCount = 0

        let restored = await controller.restorePreparedPage(
            inverse: {
                inverseCount += 1
                return false
            },
            validateOriginalLocation: { true },
            originalLocation: {
                originalCount += 1
                return true
            }
        )

        #expect(restored)
        #expect(inverseCount == 1)
        #expect(originalCount == 1)
    }

    @Test("same-resource wrong page falls back to the exact original locator")
    func wrongSameResourcePageUsesOriginalLocation() async {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var validationCount = 0
        var originalCount = 0

        let restored = await controller.restorePreparedPage(
            inverse: { true },
            validateOriginalLocation: {
                validationCount += 1
                return validationCount == 2
            },
            originalLocation: {
                originalCount += 1
                return true
            }
        )

        #expect(restored)
        #expect(validationCount == 2)
        #expect(originalCount == 1)
    }

    @Test("waiting for snapshot provider idle preserves the active capture")
    func snapshotProviderIdleWaitPreservesCapture() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let pagination = NSObject()
        let spread = NSObject()
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: pagination,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let gate = Gate()
        var captureStarted = false
        var captureWasCancelled = false
        var restoreCount = 0
        var waitFinished = false

        let capture = Task { @MainActor in
            try await provider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    captureStarted = true
                    await gate.wait()
                    if Task.isCancelled {
                        captureWasCancelled = true
                        throw CancellationError()
                    }
                    return UIImage()
                },
                restore: {
                    restoreCount += 1
                }
            )
        }
        #expect(await waitUntil { captureStarted })

        let wait = Task { @MainActor in
            await provider.waitUntilIdle()
            waitFinished = true
        }
        await nextMainRunLoop()
        #expect(!waitFinished)
        #expect(!captureWasCancelled)

        gate.open()
        #expect(try await capture.value != nil)
        await wait.value
        #expect(waitFinished)
        #expect(!captureWasCancelled)
        #expect(restoreCount == 1)
        #expect(provider.isIdle)
    }

    @Test("cancelling a snapshot provider idle waiter preserves the active capture")
    func cancellingSnapshotProviderIdleWaitPreservesCapture() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let pagination = NSObject()
        let spread = NSObject()
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: pagination,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let gate = Gate()
        var captureStarted = false
        var captureWasCancelled = false
        var waitFinished = false

        let capture = Task { @MainActor in
            try await provider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    captureStarted = true
                    await gate.wait()
                    if Task.isCancelled {
                        captureWasCancelled = true
                        throw CancellationError()
                    }
                    return UIImage()
                },
                restore: {}
            )
        }
        #expect(await waitUntil { captureStarted })

        let wait = Task { @MainActor in
            await provider.waitUntilIdle()
            waitFinished = true
        }
        await nextMainRunLoop()
        wait.cancel()
        await wait.value

        #expect(waitFinished)
        #expect(!captureWasCancelled)
        gate.open()
        #expect(try await capture.value != nil)
        #expect(!captureWasCancelled)
        #expect(provider.isIdle)
    }

    @Test("media playback and pause invalidate cover snapshots once per aggregate state change")
    func mediaStateChangesInvalidateCoverSnapshots() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .cover)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spread = try #require(paginationView.currentView as? EPUBSpreadView)
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: paginationView,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        var captureCount = 0
        let capture: () async throws -> UIImage? = {
            try await navigator.snapshotProvider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    captureCount += 1
                    return UIImage()
                },
                restore: {}
            )
        }

        #expect(try await capture() != nil)
        let revision = navigator.snapshotProvider.revision
        #expect(navigator.beginPageTurnForTesting(to: .right))
        spread.updateActiveMediaState(document: "same-url:first", isActive: true)
        #expect(navigator.snapshotProvider.revision == revision + 1)
        #expect(navigator.snapshotProvider.cachedSnapshot(for: target) == nil)
        #expect(navigator.beginPageTurnForTesting(to: .left))

        spread.updateActiveMediaState(document: "same-url:second", isActive: true)
        spread.updateActiveMediaState(document: "same-url:first", isActive: false)
        #expect(spread.hasActiveMedia)
        #expect(navigator.snapshotProvider.revision == revision + 1)
        #expect(!navigator.isPageTurnIdleForTesting)

        spread.updateActiveMediaState(document: "same-url:second", isActive: false)
        await navigator.settlePageTurn()
        #expect(!spread.hasActiveMedia)
        #expect(navigator.snapshotProvider.revision == revision + 2)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(try await capture() != nil)
        #expect(captureCount == 2)
    }

    @Test("lifecycle cancellation cleans generic reader-root page-turn siblings")
    func coverLifecycleCancellation() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let readerRoot = UIView(frame: container.bounds)
        let topChrome = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        navigator.view.frame = CGRect(x: 0, y: 64, width: 390, height: 736)
        let bottomChrome = UIView(frame: CGRect(x: 0, y: 800, width: 390, height: 44))
        readerRoot.addSubview(topChrome)
        readerRoot.addSubview(navigator.view)
        readerRoot.addSubview(bottomChrome)
        container.addSubview(readerRoot)

        let delegate = Delegate()
        delegate.pageTurnRootView = readerRoot
        navigator.delegate = delegate

        for cancel in [
            { NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil) },
            { navigator.didReceiveMemoryWarning() },
        ] {
            #expect(navigator.beginCoverPageTurnForTesting(to: .right))
            let didMountSurface = await waitUntil {
                !pageTurnSurfaces(in: container).isEmpty
            }
            #expect(didMountSurface)
            if didMountSurface {
                let activeSurfaces = pageTurnSurfaces(in: container)
                let roles = Set(activeSurfaces.compactMap(\.accessibilityIdentifier))
                #expect(roles.contains("readium.page-turn.surface.current"))
                #expect(roles.isSubset(of: Set([
                    "readium.page-turn.surface.current",
                    "readium.page-turn.surface.target",
                ])))
                #expect(activeSurfaces.allSatisfy {
                    $0.superview === container && $0.frame == readerRoot.frame
                })
            }

            cancel()
            await navigator.settlePageTurn()

            #expect(pageTurnSurfaces(in: container).isEmpty)
            #expect(container.subviews.count == 1)
            #expect(container.subviews.first === readerRoot)
            #expect(navigator.isPageTurnIdleForTesting)
        }
    }

    @Test("gesture-cancelled cover rebounds to zero, cleans up once, and never commits")
    func coverGestureCancelReset() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        #expect(controller.track(session, translationX: -50, viewportWidth: 100) == 0.5)
        var progress: CGFloat = 0.5
        var reboundCount = 0
        var cleanupCount = 0
        var commitCount = 0
        var finishCount = 0

        let restored = await controller.restoreCover(
            session,
            rebound: { restoredSession in
                #expect(restoredSession.id == session.id)
                reboundCount += 1
                progress = 0
                return true
            },
            cleanup: {
                cleanupCount += 1
            },
            finish: { restoredSession in
                finishCount += 1
                #expect(controller.finish(restoredSession))
            }
        )

        let committed = await controller.commit(session) {
            commitCount += 1
            return true
        }

        #expect(restored)
        #expect(!committed)
        #expect(progress == 0)
        #expect(reboundCount == 1)
        #expect(cleanupCount == 1)
        #expect(commitCount == 0)
        #expect(finishCount == 1)
        #expect(controller.isIdle)
    }

    @Test("failed cover restoration retains its surface until a later recovery")
    func failedCoverRestoreKeepsSurface() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var reboundCount = 0
        var cleanupCount = 0
        var finishCount = 0

        let restored = await controller.restoreCover(
            session,
            rebound: { _ in
                reboundCount += 1
                return false
            },
            cleanup: { cleanupCount += 1 },
            finish: { _ in finishCount += 1 }
        )

        #expect(!restored)
        #expect(reboundCount == 2)
        #expect(cleanupCount == 0)
        #expect(finishCount == 0)
        #expect(!controller.isIdle)
        #expect(controller.finish(session))
    }

    @Test("settle retries a failed restoration without waiting forever")
    func settleRetriesFailedCoverRestore() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var reboundCount = 0
        var didSettle = false

        let firstRestore = await controller.restoreCover(
            session,
            rebound: { _ in
                reboundCount += 1
                return false
            },
            cleanup: {},
            finish: { _ in }
        )
        #expect(!firstRestore)

        let settle = Task { @MainActor in
            await controller.settle { restoredSession in
                _ = await controller.restoreCover(
                    restoredSession,
                    rebound: { _ in
                        reboundCount += 1
                        return true
                    },
                    cleanup: {},
                    finish: { #expect(controller.finish($0)) }
                )
            }
            didSettle = true
        }

        #expect(await waitUntil { didSettle })
        if !didSettle {
            _ = controller.finish(session)
        }
        await settle.value
        #expect(reboundCount == 3)
        #expect(controller.isIdle)
    }

    @Test("continuous pagination bypasses page-turn transactions for every user style")
    func continuousPaginationRouting() async throws {
        let navigator = try makeNavigator()
        let options = NavigatorGoOptions(
            animated: true,
            otherOptions: ["probe": .string("preserved")]
        )

        for style in [
            EPUBPageTurnStyle.push,
            .none,
            .simulation,
            .cover,
        ] {
            navigator.pageTurnStyle = style
            var existingPathOptions: [NavigatorGoOptions] = []
            var pageTurnCount = 0
            var coverCount = 0

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
                },
                usingCover: { _, _ in
                    coverCount += 1
                    return true
                }
            )

            #expect(result)
            #expect(existingPathOptions == [options])
            #expect(pageTurnCount == 0)
            #expect(coverCount == 0)
        }
    }

    @Test("reduce motion and VoiceOver route horizontal turns through none")
    func accessibleHorizontalRouting() async throws {
        let navigator = try makeNavigator()
        navigator.pageTurnStyle = .cover
        let options = NavigatorGoOptions(
            animated: true,
            otherOptions: ["probe": .string("preserved")]
        )

        for flags in [
            (isReduceMotionEnabled: true, isVoiceOverRunning: false),
            (isReduceMotionEnabled: false, isVoiceOverRunning: true),
        ] {
            var existingPathCount = 0
            var pageTurnOptions: [NavigatorGoOptions] = []
            var coverCount = 0

            let result = await navigator.routePageTurn(
                to: .right,
                options: options,
                axis: .horizontalPaged,
                isReduceMotionEnabled: flags.isReduceMotionEnabled,
                isVoiceOverRunning: flags.isVoiceOverRunning,
                usingExistingPath: { _, _ in
                    existingPathCount += 1
                    return true
                },
                usingPageTurn: { _, routedOptions in
                    pageTurnOptions.append(routedOptions)
                    return true
                },
                usingCover: { _, _ in
                    coverCount += 1
                    return true
                }
            )

            #expect(result)
            #expect(existingPathCount == 0)
            #expect(pageTurnOptions == [.none])
            #expect(coverCount == 0)
        }
    }

    @Test("programmatic cover with animated false uses the instant transaction path")
    func instantProgrammaticCoverRouting() async throws {
        let navigator = try makeNavigator()
        navigator.pageTurnStyle = .cover
        let options = NavigatorGoOptions(
            animated: false,
            otherOptions: ["probe": .string("preserved")]
        )
        var pageTurnOptions: [NavigatorGoOptions] = []
        var coverOptions: [NavigatorGoOptions] = []

        let result = await navigator.routePageTurn(
            to: .right,
            options: options,
            axis: .horizontalPaged,
            isReduceMotionEnabled: false,
            isVoiceOverRunning: false,
            usingExistingPath: { _, _ in false },
            usingPageTurn: { _, routedOptions in
                pageTurnOptions.append(routedOptions)
                return true
            },
            usingCover: { _, routedOptions in
                coverOptions.append(routedOptions)
                return true
            }
        )

        #expect(result)
        #expect(pageTurnOptions.isEmpty)
        #expect(coverOptions == [options])
    }

    @Test("reduce motion and VoiceOver keep continuous routing on the existing path without animation")
    func accessibleContinuousRouting() async throws {
        let navigator = try makeNavigator()
        navigator.pageTurnStyle = .push
        let options = NavigatorGoOptions(
            animated: true,
            otherOptions: ["probe": .string("preserved")]
        )

        for flags in [
            (isReduceMotionEnabled: true, isVoiceOverRunning: false),
            (isReduceMotionEnabled: false, isVoiceOverRunning: true),
        ] {
            var existingPathOptions: [NavigatorGoOptions] = []
            var pageTurnCount = 0
            var coverCount = 0

            let result = await navigator.routePageTurn(
                to: .right,
                options: options,
                axis: .verticalContinuous,
                isReduceMotionEnabled: flags.isReduceMotionEnabled,
                isVoiceOverRunning: flags.isVoiceOverRunning,
                usingExistingPath: { _, routedOptions in
                    existingPathOptions.append(routedOptions)
                    return true
                },
                usingPageTurn: { _, _ in
                    pageTurnCount += 1
                    return true
                },
                usingCover: { _, _ in
                    coverCount += 1
                    return true
                }
            )

            #expect(result)
            #expect(existingPathOptions.count == 1)
            #expect(existingPathOptions.first?.animated == false)
            #expect(existingPathOptions.first?.otherOptions == options.otherOptions)
            #expect(pageTurnCount == 0)
            #expect(coverCount == 0)
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

    @Test("a failed locator calculation does not publish its viewport early")
    func failedLocationCalculationKeepsPublishedViewport() async throws {
        let oldLocation = makeLocator(href: "old.xhtml", progression: 0)
        let navigator = try makeNavigator(initialLocation: oldLocation)
        let oldViewport = NavigatorViewport(
            resources: [
                .init(href: oldLocation.href, progression: 0 ... 0.25)
            ],
            progression: 0 ... 0.25
        )
        let rejectedViewport = NavigatorViewport(
            resources: [
                .init(
                    href: AnyURL(string: "rejected.xhtml")!,
                    progression: 0.5 ... 0.75
                )
            ],
            progression: 0.5 ... 0.75
        )
        #expect(await navigator.publishCurrentLocation {
            (oldLocation, oldViewport)
        })

        let published = await navigator.publishCurrentLocation {
            (nil, rejectedViewport)
        }

        #expect(!published)
        #expect(navigator.currentLocation == oldLocation)
        #expect(navigator.viewport == oldViewport)
    }

    @Test("surface preparation refuses a transaction when the exact original preview is unavailable")
    func missingOriginalPreviewRejectsSurfacePreparation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        var navigationCount = 0
        navigator.pageTurnPreviewCalculationForTesting = { (nil, nil) }
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return true
        }

        #expect(!(await navigator.goForward(options: .animated)))
        await navigator.settlePageTurn()

        #expect(navigationCount == 0)
        #expect(root.snapshotCount == 2)
        #expect(delegate.locationChangeCount == 1)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("surface preparation waits for a transiently unavailable exact original preview")
    func transientOriginalPreviewDoesNotDropPageTurn() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        let targetViewport = NavigatorViewport(
            resources: [
                .init(href: target.href, progression: 0 ... 0.25)
            ],
            progression: 0.5 ... 0.75
        )
        var calculationCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            calculationCount += 1
            switch calculationCount {
            case 1:
                return (nil, nil)
            case 2:
                return (original, originalViewport)
            default:
                return (target, targetViewport)
            }
        }
        navigator.pageTurnNavigationForTesting = { _, _ in true }
        navigator.pageTurnLocationCalculationForTesting = {
            (target, targetViewport)
        }

        #expect(await navigator.goForward(options: .animated))

        #expect(calculationCount >= 3)
        #expect(delegate.previews.contains { $0.0 == target })
        #expect(delegate.previewEndCount == 1)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("a missing target preview prevents target capture and commit")
    func missingTargetPreviewRejectsSurfaceCommit() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        var calculationCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            calculationCount += 1
            return calculationCount == 1
                ? (original, originalViewport)
                : (nil, originalViewport)
        }
        navigator.pageTurnNavigationForTesting = { _, _ in true }

        #expect(!(await navigator.goForward(options: .animated)))
        await navigator.settlePageTurn()

        #expect(calculationCount >= 2)
        #expect(root.snapshotCount == 2)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.currentLocation == original)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("cancellation restores the exact original preview for two frames before recapture and cleanup")
    func cancellationRestoresOriginalPreviewBeforeCleanup() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        let targetViewport = NavigatorViewport(
            resources: [
                .init(href: target.href, progression: 0 ... 0.25)
            ],
            progression: 0.5 ... 0.75
        )
        var previewCalculationCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            previewCalculationCount += 1
            return previewCalculationCount == 1
                ? (original, originalViewport)
                : (target, targetViewport)
        }
        navigator.pageTurnNavigationForTesting = { _, _ in true }
        let firstFrameGate = Gate()
        var frameCount = 0
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            frameCount += 1
            if frameCount == 1 {
                await firstFrameGate.wait()
            }
        }
        var recapturedAfterOriginalPreview = false
        root.onSnapshot = {
            if root.snapshotCount >= 3 {
                recapturedAfterOriginalPreview =
                    delegate.previews.last?.0 == original
            }
        }

        let turn = Task { @MainActor in
            await navigator.goForward(options: .animated)
        }
        #expect(await waitUntil { frameCount == 1 })
        turn.cancel()
        firstFrameGate.open()

        #expect(!(await turn.value))
        await navigator.settlePageTurn()

        #expect(frameCount >= 6)
        #expect(delegate.previews.count >= 3)
        #expect(delegate.previews.dropLast().last?.0 == original)
        #expect(delegate.previews.last?.0 == nil)
        #expect(recapturedAfterOriginalPreview)
        #expect(delegate.locationChangeCount == 0)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("gesture restoration exhaustion reaches terminal recovery and permits the next gesture")
    func gestureRestoreFailureDoesNotRemainTracking() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        let unavailableOriginal = makeLocator(href: "missing-original.xhtml", progression: 0.25)
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        let viewport = try #require(navigator.viewport)
        var previewCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            previewCount += 1
            return previewCount == 1
                ? (unavailableOriginal, viewport)
                : (target, viewport)
        }
        var navigationCount = 0
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return navigationCount == 1
        }
        navigator.pageTurnLocationCalculationForTesting = {
            (target, viewport)
        }

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        #expect(await waitUntil {
            navigator.pageTurnSurfaceTransactionEvidenceForTesting.hasPreparedTarget
        })
        navigator.handlePageTurnPanForTesting(
            state: .cancelled,
            translationX: 0,
            velocityX: 0
        )

        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        #expect(navigationCount == 3)
        #expect(delegate.locationChangeCount == 1)
        #expect(pageTurnSurfaces(in: container).isEmpty)

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        #expect(!navigator.isPageTurnControllerIdleForTesting)
        navigator.handlePageTurnPanForTesting(
            state: .cancelled,
            translationX: 0,
            velocityX: 0
        )
    }

    @Test("irreversible surface commit reports publication failure and clears preview")
    func surfaceCommitPublicationFailureIsTerminalFailure() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        navigator.pageTurnLocationCalculationForTesting = { (nil, nil) }

        let result = await navigator.goForward(options: .animated)

        #expect(!result)
        #expect(delegate.previewEndCount == 1)
        #expect(delegate.locationChangeCount == 0)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
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
        let session = controller.begin(to: .right, readingProgression: .ltr)

        #expect(session != nil)
        #expect(controller.begin(to: .left, readingProgression: .ltr) == nil)
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
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
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
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
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

    @Test("cancellation and two settle waiters await one irreversible publish and finish")
    func committedTurnIgnoresCancellation() async throws {
        let handoffGate = Gate()
        let publishGate = Gate()
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        var didStart = false
        var didHandoff = false
        var publishCount = 0
        var finishCount = 0
        var settledCount = 0
        var settleStartedCount = 0

        let turnTask = Task { @MainActor in
            await controller.commit(session) {
                defer {
                    finishCount += 1
                    #expect(controller.finish(session))
                }
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
        let firstSettle = Task { @MainActor in
            settleStartedCount += 1
            await controller.settle(restore: { _ in })
            settledCount += 1
        }
        let secondSettle = Task { @MainActor in
            settleStartedCount += 1
            await controller.settle(restore: { _ in })
            settledCount += 1
        }

        #expect(await waitUntil { settleStartedCount == 2 })
        handoffGate.open()
        #expect(await waitUntil { didHandoff })
        #expect(settledCount == 0)
        #expect(!controller.isIdle)

        publishGate.open()
        #expect(await turnTask.value)
        await firstSettle.value
        await secondSettle.value

        #expect(publishCount == 1)
        #expect(finishCount == 1)
        #expect(settledCount == 2)
        #expect(controller.isIdle)
    }

    @Test("a failed moving publish releases state and idle refresh gets a second chance")
    func failedPublishReleasesState() async throws {
        var movingPublishCount = 0
        var idleRefreshCount = 0
        let controller = EPUBPageTurnController {
            idleRefreshCount += 1
        }
        let session = try #require(controller.begin(to: .left, readingProgression: .ltr))

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

    @Test("a failed irreversible operation cannot leave the controller committing")
    func failedIrreversibleOperationReleasesState() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))

        let result = await controller.commit(session) { false }

        #expect(!result)
        #expect(controller.isIdle)
        #expect(!controller.isCommitting)
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
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))

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

    private func makeNavigator(
        notificationCenter: NotificationCenter,
        accessibilityStatus: AccessibilityStatusBox
    ) throws -> EPUBNavigatorViewController {
        try EPUBNavigatorViewController(
            publication: Publication(
                manifest: Manifest(metadata: Metadata(title: "Test"))
            ),
            initialLocation: nil,
            config: .init(),
            notificationCenter: notificationCenter,
            accessibilityStatusProvider: {
                accessibilityStatus.read()
            }
        )
    }

    private func makeMountedNavigator(
        layout: Layout? = nil,
        pageTurnStyle: EPUBPageTurnStyle,
        notificationCenter: NotificationCenter? = nil,
        accessibilityStatus: AccessibilityStatusBox? = nil
    ) async throws -> EPUBNavigatorViewController {
        let link = Link(href: "chapter.xhtml", mediaType: .xhtml)
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test", layout: layout),
                readingOrder: [link]
            ),
            container: SingleResourceContainer(
                resource: DataResource(string: "<html><body><p>Page</p></body></html>"),
                at: link.url()
            )
        )
        let config = EPUBNavigatorViewController.Configuration(pageTurnStyle: pageTurnStyle)
        let navigator: EPUBNavigatorViewController
        if let notificationCenter, let accessibilityStatus {
            navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: nil,
                config: config,
                notificationCenter: notificationCenter,
                accessibilityStatusProvider: {
                    accessibilityStatus.read()
                }
            )
        } else {
            navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: nil,
                config: config
            )
        }
        navigator.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        navigator.loadViewIfNeeded()
        await navigator.initialized()
        navigator.view.layoutIfNeeded()
        return navigator
    }

    private func currentPaginationView(
        in navigator: EPUBNavigatorViewController
    ) -> PaginationView? {
        navigator.view.subviews.compactMap { $0 as? PaginationView }.last
    }

    private func rootPanRecognizers(
        in navigator: EPUBNavigatorViewController
    ) -> [UIPanGestureRecognizer] {
        navigator.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
    }

    private func pageTurnSurfaces(in view: UIView) -> [UIView] {
        view.subviews.flatMap { child in
            let descendants = pageTurnSurfaces(in: child)
            guard child.accessibilityIdentifier?.hasPrefix("readium.page-turn.surface.") == true else {
                return descendants
            }
            return [child] + descendants
        }
    }

    private func makeLoadedNavigator(
        pageTurnStyle: EPUBPageTurnStyle = .push,
        notificationCenter: NotificationCenter? = nil,
        accessibilityStatus: AccessibilityStatusBox? = nil
    ) async throws -> (EPUBNavigatorViewController, Delegate) {
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
        let initialLocation = makeLocator(href: "chapter-1.xhtml", progression: 0)
        let config = EPUBNavigatorViewController.Configuration(pageTurnStyle: pageTurnStyle)
        let navigator = if let notificationCenter, let accessibilityStatus {
            try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: config,
                notificationCenter: notificationCenter,
                accessibilityStatusProvider: {
                    accessibilityStatus.read()
                }
            )
        } else {
            try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: config
            )
        }
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

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func postFromBackground(
        _ name: Notification.Name,
        to notificationCenter: NotificationCenter
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                notificationCenter.post(name: name, object: nil)
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class ViewModelDelegate: @MainActor EPUBNavigatorViewModelDelegate {
    private(set) var invalidationCount = 0

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        runScript script: String,
        in scope: EPUBScriptScope
    ) {}

    func epubNavigatorViewModelInvalidatePaginationView(
        _ viewModel: EPUBNavigatorViewModel
    ) {
        invalidationCount += 1
    }
}

@MainActor
private final class AccessibilityStatusBox {
    var isReduceMotionEnabled = false
    var isVoiceOverRunning = false
    private(set) var wereAllReadsOnMainThread = true

    func read() -> (isReduceMotionEnabled: Bool, isVoiceOverRunning: Bool) {
        wereAllReadsOnMainThread = wereAllReadsOnMainThread && Thread.isMainThread
        return (isReduceMotionEnabled, isVoiceOverRunning)
    }
}

private final class ObserverRemovalTrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private(set) var removeObserverCount = 0

    override func removeObserver(_ observer: Any) {
        removeObserverCount += 1
        super.removeObserver(observer)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func set() {
        lock.withLock {
            storedValue = true
        }
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
private final class SnapshotObservingView: UIView {
    var onSnapshot: (() -> Void)?
    var shouldFailSnapshots = false
    private(set) var snapshotCount = 0

    override func snapshotView(afterScreenUpdates afterUpdates: Bool) -> UIView? {
        snapshotCount += 1
        onSnapshot?()
        guard !shouldFailSnapshots else { return nil }
        return super.snapshotView(afterScreenUpdates: afterUpdates)
    }
}

@MainActor
private final class Delegate: EPUBNavigatorDelegate {
    weak var pageTurnRootView: UIView?
    private(set) var presentationChangeCount = 0
    private(set) var locationChangeCount = 0
    private(set) var previewEndCount = 0
    private(set) var previews: [(Locator?, NavigatorViewport?)] = []
    private(set) var errorCount = 0

    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView? {
        pageTurnRootView
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationChangeCount += 1
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        previewLocationDidChange locator: Locator?,
        viewport: NavigatorViewport?
    ) {
        previews.append((locator, viewport))
        if locator == nil {
            previewEndCount += 1
        }
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
