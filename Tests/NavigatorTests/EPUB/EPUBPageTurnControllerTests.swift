//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreImage
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

    @Test("capture-time page turn style assignments immediately route with the requested style")
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

        navigator.pageTurnStyle = .simulation

        // A capture lease may postpone cache cleanup, but it must never make
        // the next navigation transaction read the previous user selection.
        #expect(navigator.pageTurnStyle == .simulation)
        var routedOptions: [NavigatorGoOptions] = []
        let routed = await navigator.routePageTurn(
            to: .right,
            options: .init(animated: true),
            axis: .horizontalPaged,
            isReduceMotionEnabled: false,
            isVoiceOverRunning: false,
            usingExistingPath: { _, _ in false },
            usingPageTurn: { _, options in
                routedOptions.append(options)
                return true
            },
            usingCover: { _, _ in false }
        )
        #expect(routed)
        #expect(routedOptions.count == 1)
        #expect(routedOptions.first == .init(animated: true))

        navigator.pageTurnStyle = .push
        #expect(navigator.pageTurnStyle == .push)
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

    @Test("public settle is bounded when snapshot restoration ignores cancellation")
    func settlePageTurnDeadlineDoesNotWaitForeverForSnapshotRestore() async throws {
        let navigator = try await makeMountedNavigator(
            layout: .reflowable,
            pageTurnStyle: .push
        )
        let pagination = try #require(currentPaginationView(in: navigator))
        let spread = try #require(pagination.currentView as? EPUBSpreadView)
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: pagination,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let restoreGate = Gate()
        var didEnterRestore = false
        let capture = Task {
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
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(20))
        var didSettle = false
        let settle = Task { @MainActor in
            await navigator.settlePageTurn()
            didSettle = true
        }

        #expect(await waitUntil { didSettle })
        #expect(!navigator.snapshotProvider.isIdle)

        restoreGate.open()
        _ = try await capture.value
        await settle.value
    }

    @Test("relative navigation waits for snapshot restoration before mutating")
    func relativeNavigationDoesNotRaceSnapshotRestore() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)
        let pagination = try #require(currentPaginationView(in: navigator))
        let spread = try #require(pagination.currentView as? EPUBSpreadView)
        let target = EPUBPageTurnSnapshotTargetIdentity(
            pagination: pagination,
            spread: spread,
            resourceIndex: 0,
            pageIndex: 0
        )
        let captureGate = Gate()
        var captureStarted = false
        let capture = Task {
            try await navigator.snapshotProvider.capture(
                target: target,
                sourceIdentity: { target },
                isBlocked: { false },
                capture: {
                    captureStarted = true
                    await captureGate.wait()
                    return UIImage()
                },
                restore: {}
            )
        }
        #expect(await waitUntil { captureStarted })

        var navigationCount = 0
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return true
        }
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(20))

        let result = await navigator.goForward(options: .none)

        #expect(!result)
        #expect(navigationCount == 0)
        captureGate.open()
        _ = try await capture.value
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

    @Test("none pan maps horizontal swipes independent of reading progression")
    func nonePanDirection() {
        #expect(EPUBPageTurnInteraction.direction(for: CGPoint(x: -1, y: 0)) == .right)
        #expect(EPUBPageTurnInteraction.direction(for: CGPoint(x: 1, y: 0)) == .left)
        #expect(EPUBPageTurnInteraction.direction(for: CGPoint(x: 10, y: 11)) == nil)
        #expect(EPUBPageTurnInteraction.direction(for: CGPoint(x: 120, y: 100)) == nil)
        #expect(EPUBPageTurnInteraction.direction(for: CGPoint(x: -121, y: 100)) == .right)
    }

    @Test("simulation keeps the first swipe progress while the target raster is prepared")
    func simulationRetainsColdTargetProgress() throws {
        let image = try #require(
            UIGraphicsImageRenderer(size: CGSize(width: 30, height: 90))
                .image { _ in UIColor.black.setFill() }
                .cgImage
        )
        let controller = try #require(EPUBPageCurlController(
            currentImage: image,
            paperColor: .black,
            isForward: true
        ))

        controller.render(progress: 0.41)
        #expect(!controller.hasTarget)
        controller.setTargetImage(image)

        #expect(controller.hasTarget)
        #expect(controller.progress == 0.41)
    }

    @Test("simulation always uses a left hinge for forward peel and reverse uncurl")
    func simulationDirectionMapping() {
        #expect(EPUBPageCurlRenderView.angle(isForward: true) == .pi)
        #expect(EPUBPageCurlRenderView.angle(isForward: false) == .pi)
        #expect(EPUBPageCurlRenderView.leftHingeAngle == .pi)

        let ltrForward = PageTurnSession(
            direction: .right,
            readingProgression: .ltr
        )
        let ltrBackward = PageTurnSession(
            direction: .left,
            readingProgression: .ltr
        )
        let rtlForward = PageTurnSession(
            direction: .left,
            readingProgression: .rtl
        )
        #expect(ltrForward.isForward)
        #expect(!ltrBackward.isForward)
        #expect(ltrForward.physicalCompletionDirection == .left)
        #expect(rtlForward.physicalCompletionDirection == .right)
    }

    @Test("simulation uses a mirrored current surface for the curl backside")
    func simulationMirrorsCurrentSurfaceForBackside() throws {
        let current = makeSideBySideImage(
            left: .red,
            right: .blue
        )
        let view = try #require(EPUBPageCurlRenderView(
            currentImage: current,
            paperColor: .black,
            isForward: true
        ))

        let backside = try #require(renderedCGImage(view.backsideImageForRendering()))
        let renderedCurrent = try #require(renderedCGImage(CIImage(cgImage: current)))
        let leftBackside = try #require(backside.pixelBytes(at: CGPoint(
            x: CGFloat(backside.width) * 0.05,
            y: CGFloat(backside.height) * 0.5
        )))
        let rightCurrent = try #require(renderedCurrent.pixelBytes(at: CGPoint(
            x: CGFloat(renderedCurrent.width) * 0.95,
            y: CGFloat(renderedCurrent.height) * 0.5
        )))

        #expect(leftBackside == rightCurrent)
    }

    @Test("simulation mounts a trackable curl before the target image is captured")
    func simulationMountsCurlBeforeTargetCapture() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 180))
        let root = UIView(frame: parent.bounds)
        root.backgroundColor = .white
        parent.addSubview(root)

        let animator = try #require(EPUBPageTurnSurfaceAnimator(
            rootView: root,
            style: .simulation,
            physicalCompletionDirection: .left,
            isForward: true
        ))
        let curl = try #require(
            parent.subviews.first {
                $0.accessibilityIdentifier == "readium.page-turn.curl"
            } as? EPUBPageCurlRenderView
        )

        #expect(!animator.hasTarget)
        animator.render(progress: 0.4)
        #expect(abs(curl.progress - 0.4) < 0.001)
    }

    @Test("simulation refreshes the mirrored backside after recapturing the current surface")
    func simulationRefreshesBacksideAfterRecapture() throws {
        let initial = makeSideBySideImage(left: .red, right: .blue)
        let recaptured = makeSideBySideImage(left: .green, right: .yellow)
        let view = try #require(EPUBPageCurlRenderView(
            currentImage: initial,
            paperColor: .black,
            isForward: true
        ))
        let initialBackside = try #require(renderedCGImage(view.backsideImageForRendering()))
        let initialLeft = try #require(initialBackside.pixelBytes(at: CGPoint(
            x: CGFloat(initialBackside.width) * 0.05,
            y: CGFloat(initialBackside.height) * 0.5
        )))

        view.setCurrentImage(recaptured)

        let recapturedBackside = try #require(renderedCGImage(view.backsideImageForRendering()))
        let recapturedCurrent = try #require(renderedCGImage(CIImage(cgImage: recaptured)))
        let recapturedLeft = try #require(recapturedBackside.pixelBytes(at: CGPoint(
            x: CGFloat(recapturedBackside.width) * 0.05,
            y: CGFloat(recapturedBackside.height) * 0.5
        )))
        let recapturedRight = try #require(recapturedCurrent.pixelBytes(at: CGPoint(
            x: CGFloat(recapturedCurrent.width) * 0.95,
            y: CGFloat(recapturedCurrent.height) * 0.5
        )))

        #expect(recapturedLeft == recapturedRight)
        #expect(recapturedLeft != initialLeft)
    }

    @Test("simulation curl output keeps top document and bottom surface content on the page")
    func simulationCurlOutputKeepsWholeSurfaceContent() throws {
        let current = makeBandedImage(colors: [.red, .green, .blue])
        let target = makeBandedImage(colors: [.cyan, .magenta, .yellow])
        let view = try #require(EPUBPageCurlRenderView(
            currentImage: current,
            paperColor: .black,
            isForward: true
        ))
        view.setTargetImage(target)
        view.progress = 0.5

        let backside = try #require(renderedCGImage(view.backsideImageForRendering()))
        let backsideBands = try [CGFloat(1.0 / 6), 0.5, 5.0 / 6].map {
            try #require(backside.pixelBytes(at: CGPoint(
                x: CGFloat(backside.width) * 0.44,
                y: CGFloat(backside.height) * $0
            )))
        }
        let output = try #require(renderedCGImage(view.outputImage()))
        let bands = try [CGFloat(1.0 / 6), 0.5, 5.0 / 6].map {
            try #require(output.pixelBytes(at: CGPoint(
                x: CGFloat(output.width) * 0.44,
                y: CGFloat(output.height) * $0
            )))
        }

        #expect(backsideBands[0] != backsideBands[1])
        #expect(backsideBands[1] != backsideBands[2])
        #expect(bands[0] != bands[1])
        #expect(bands[1] != bands[2])
        #expect(bands.allSatisfy { $0.contains { $0 > 32 } })
    }

    @Test("simulation curl peels forward and uncurls backward with a left hinge")
    func simulationCurlOutputFollowsTurnDirection() throws {
        let current = makeSolidImage(.red)
        let target = makeSolidImage(.green)

        let forward = try #require(EPUBPageCurlRenderView(
            currentImage: current,
            paperColor: .black,
            isForward: true
        ))
        forward.setTargetImage(target)
        forward.progress = 0.5
        let forwardOutput = try #require(renderedCGImage(forward.outputImage()))
        let forwardOutgoing = try #require(
            forwardOutput.pixelBytes(at: CGPoint(
                x: CGFloat(forwardOutput.width) * (1.0 / 3),
                y: CGFloat(forwardOutput.height) * 0.5
            ))
        )
        let forwardIncoming = try #require(
            forwardOutput.pixelBytes(at: CGPoint(
                x: CGFloat(forwardOutput.width) * (2.0 / 3),
                y: CGFloat(forwardOutput.height) * 0.5
            ))
        )
        #expect(isPredominantlyRed(forwardOutgoing))
        #expect(isPredominantlyGreen(forwardIncoming))

        let backward = try #require(EPUBPageCurlRenderView(
            currentImage: current,
            paperColor: .black,
            isForward: false
        ))
        backward.setTargetImage(target)
        backward.progress = 0.5
        let backwardOutput = try #require(renderedCGImage(backward.outputImage()))
        let covered = try #require(
            backwardOutput.pixelBytes(at: CGPoint(
                x: CGFloat(backwardOutput.width) * (1.0 / 3),
                y: CGFloat(backwardOutput.height) * 0.5
            ))
        )
        let stillCurrent = try #require(
            backwardOutput.pixelBytes(at: CGPoint(
                x: CGFloat(backwardOutput.width) * (2.0 / 3),
                y: CGFloat(backwardOutput.height) * 0.5
            ))
        )
        #expect(isPredominantlyGreen(covered))
        #expect(isPredominantlyRed(stillCurrent))
    }

    @Test("simulation rasterizes top, document, and bottom as one reader surface")
    func simulationRasterizesWholeReaderSurface() throws {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 90))
        for (color, y) in [(UIColor.red, 0), (.green, 30), (.blue, 60)] {
            let block = UIView(frame: CGRect(x: 0, y: y, width: 30, height: 30))
            block.backgroundColor = color
            root.addSubview(block)
        }

        let image = try #require(EPUBPageCurlController.rasterize(root))
        let blocks = [15, 45, 75].compactMap {
            image.cgImage?.pixelBytes(at: CGPoint(
                x: 15 * image.scale,
                y: CGFloat($0) * image.scale
            ))
        }

        #expect(blocks.count == 3)
        #expect(Set(blocks).count == 3)
    }

    @Test("simulation completes the first cold cross-resource swipe with one publish")
    func simulationCompletesColdCrossResourceSwipe() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .simulation
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let window = UIWindow(frame: container.bounds)
        let root = UIView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        window.addSubview(container)
        window.isHidden = false
        delegate.pageTurnRootView = root
        delegate.pageTurnSurfaceController = makePageTurnSurfaceController(
            root: root
        )
        navigator.view.layoutIfNeeded()
        await nextMainRunLoop()
        await navigator.settlePageTurn()
        #expect(await waitUntil { navigator.isNavigationQuiescentForTesting })
        delegate.resetLocationChanges()
        #expect(navigator.armColdForwardPageTurnTargetForTesting())

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -700
        )

        let didMountCurl = await waitUntil {
            ((pageCurlViews(in: container).first as? EPUBPageCurlRenderView)?
                .progress ?? 0) > 0.22
        }
        #expect(didMountCurl)
        let renderView = try #require(
            pageCurlViews(in: container).first as? EPUBPageCurlRenderView
        )
        #expect(renderView.progress > 0.22)

        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -100,
            velocityX: -700
        )
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(delegate.locationChangeCount == 1)
        #expect(pageCurlViews(in: container).isEmpty)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("simulation without a live surface controller degrades to push instead of curling")
    func simulationWithoutLiveSurfaceControllerDegradesToPush() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .simulation
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        // No pageTurnSurfaceController: curl cannot install, but push can use
        // the plain root and must still complete the turn.
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -300,
            velocityX: -700
        )
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(pageCurlViews(in: container).isEmpty)
        #expect(pageTurnSurfaces(in: container).isEmpty)

        // With an explicit live surface host, simulation can curl.
        #expect(await navigator.goBackward(options: .none))
        await navigator.settlePageTurn()
        delegate.pageTurnSurfaceController = makePageTurnSurfaceController(
            root: root
        )
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -300,
            velocityX: -700
        )
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
    }

    @Test("simulation without any page-turn root degrades to none and still turns")
    func simulationWithoutAnyRootDegradesToNone() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .simulation
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        // Neither simulation host nor push root — surface install cannot work,
        // but `.none` needs no snapshot root and must still complete the turn.
        delegate.pageTurnRootView = nil

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -300,
            velocityX: -700
        )
        await navigator.settlePageTurn()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(pageCurlViews(in: container).isEmpty)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
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
            (.rtl, .right, 1),
            (.rtl, .left, -1),
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
            currentPaginationView(in: navigator)?.currentIndex == 1
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
            currentPaginationView(in: navigator)?.currentIndex == 1
        })
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("a reversible turn accepts the full immediate reverse gesture")
    func animatedPanSerializesColdChapterSeamAndReverse() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .push,
            chapterCount: 3
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        #expect(await navigator.goForward(options: .none))
        await navigator.settlePageTurn()
        delegate.resetLocationChanges()
        let displayFrameGate = Gate()
        var isWaitingForDisplayFrame = false
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            guard !isWaitingForDisplayFrame else { return }
            isWaitingForDisplayFrame = true
            await displayFrameGate.wait()
        }
        var commitValidationCount = 0
        navigator.pageTurnWillValidateCommitForTesting = {
            commitValidationCount += 1
            #expect(delegate.locationChangeCount == 0)
            #expect(currentPaginationView(in: navigator)?.currentIndex == 2)
        }

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: 700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: 100,
            velocityX: 700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: 100,
            velocityX: 700
        )
        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 0
                && isWaitingForDisplayFrame
        })

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .ended,
            translationX: -100,
            velocityX: -700
        )
        displayFrameGate.open()
        await navigator.settlePageTurn()

        // The reverse must be accepted and land on the next chapter. After an
        // interrupt, surface prepare may fall back to instant commit — that is
        // still a successful reverse (location publishes once). Surface commit
        // validation runs only when the full overlay path is ready.
        #expect(navigator.pageTurnPendingQueueCountForTesting >= 1)
        #expect(navigator.pageTurnPendingResumeCountForTesting >= 1)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-3.xhtml"))
        #expect(delegate.locationChangeCount == 1)
        #expect(commitValidationCount <= 1)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("external cancellation discards an immediate reverse gesture")
    func externalCancellationDiscardsQueuedReverseGesture() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .push,
            chapterCount: 3
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        #expect(await navigator.goForward(options: .none))
        await navigator.settlePageTurn()
        let original = try #require(navigator.currentLocation)
        delegate.resetLocationChanges()
        let displayFrameGate = Gate()
        var isWaitingForDisplayFrame = false
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            guard !isWaitingForDisplayFrame else { return }
            isWaitingForDisplayFrame = true
            await displayFrameGate.wait()
        }

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
                && isWaitingForDisplayFrame
        })
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

        navigator.didReceiveMemoryWarning()
        displayFrameGate.open()
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation == original)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("style interaction mode waits for a cancelling surface transaction to finish")
    func styleInteractionModeWaitsForCancelledSurfaceTransaction() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -700
        )
        #expect(await waitUntil { pageTurnSurfaces(in: container).count == 2 })

        let restoreGate = Gate()
        var isRestoring = false
        navigator.pageTurnPreparedPageRestoreForTesting = {
            isRestoring = true
            await restoreGate.wait()
            return true
        }
        let updateCount = navigator.pageTurnInteractionModeUpdateCountForTesting

        navigator.pageTurnStyle = .none

        #expect(await waitUntil { isRestoring })
        #expect(navigator.pageTurnInteractionModeUpdateCountForTesting == updateCount)

        restoreGate.open()
        await navigator.settlePageTurn()

        #expect(navigator.pageTurnInteractionModeUpdateCountForTesting == updateCount + 1)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("hard abort prevents failed surface recovery from resurrecting its old session")
    func hardAbortRetiresFailedSurfaceRecovery() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -700
        )
        #expect(await waitUntil { pageTurnSurfaces(in: container).count == 2 })

        let restoreGate = Gate()
        var isRestoring = false
        navigator.pageTurnPreparedPageRestoreForTesting = {
            isRestoring = true
            await restoreGate.wait()
            return false
        }
        navigator.pageTurnStyle = .none
        #expect(await waitUntil { isRestoring })

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        var didOpenNewSession = false
        let newSession = Task { @MainActor in
            didOpenNewSession = await navigator.beginPageTurnForTesting(to: .right)
            return didOpenNewSession
        }
        await Task.yield()
        #expect(!didOpenNewSession)

        restoreGate.open()
        #expect(await newSession.value)
        #expect(!navigator.isPageTurnControllerIdleForTesting)

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("hard abort cancels the active detached page-turn recovery")
    func hardAbortCancelsActiveDetachedRecovery() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        navigator.handlePageTurnPanForTesting(
            state: .changed,
            translationX: -100,
            velocityX: -700
        )
        #expect(await waitUntil { pageTurnSurfaces(in: container).count == 2 })

        var recoveryStarted = false
        var recoveryObservedCancellation = false
        var allowRecoveryExit = false
        navigator.pageTurnPreparedPageRestoreForTesting = {
            recoveryStarted = true
            while !Task.isCancelled, !allowRecoveryExit {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            recoveryObservedCancellation = Task.isCancelled
            return false
        }
        navigator.pageTurnStyle = .none
        #expect(await waitUntil { recoveryStarted })

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(recoveryObservedCancellation)
        allowRecoveryExit = true
        await navigator.settlePageTurn()
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("external cancellation clears a queued none gesture before the next pan")
    func noneCancellationDoesNotLeaveQueuedGesture() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        var navigationCount = 0
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return true
        }

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
        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: 700
        )
        navigator.pageTurnStyle = .simulation
        navigator.pageTurnStyle = .none

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
        await navigator.settlePageTurn()

        #expect(navigationCount == 1)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("an expired begin drain cannot open a late page-turn session")
    func expiredBeginDrainCannotOpenLateSession() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)
        let original = try #require(navigator.currentLocation)
        let restoreGate = Gate()
        var isRestoring = false
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            isRestoring = true
            await restoreGate.wait()
            return true
        }
        navigator.queueHardAbortRestoreForTesting(original)
        #expect(await waitUntil { isRestoring })
        let operation = NavigationOperation(
            operationID: 901,
            intent: .relative(.forward),
            timeout: .seconds(1)
        )
        let begin = Task { @MainActor in
            await navigator.beginPageTurnForTesting(
                to: .right,
                operation: operation
            )
        }
        await Task.yield()

        operation.cancel()
        let result = await begin.value

        #expect(result.isCancelled)
        #expect(navigator.isPageTurnControllerIdleForTesting)
        restoreGate.open()
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()
    }

    @Test("hard-abort snapping runs inside the restore executor lease")
    func hardAbortSnapRunsInsideExecutorLease() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)
        let original = try #require(navigator.currentLocation)
        navigator.pageTurnOriginalLocationRestoreForTesting = { true }

        navigator.queueHardAbortRestoreForTesting(original)
        await navigator.awaitPendingHardAbortLocationRestoreForTesting()

        #expect(navigator.pageTurnHardAbortSnapHadExecutorLeaseForTesting == true)
    }

    @Test("a queued accessibility cancel bypasses stalled preparation")
    func queuedAccessibilityCancelKeepsSettleLive() async throws {
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
        let navigationGate = Gate()
        var navigationStarted = false
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationStarted = true
            await navigationGate.wait()
            return false
        }

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
        var didSettle = false
        let settle = Task { @MainActor in
            await navigator.settlePageTurn()
            didSettle = true
        }

        let settledBeforeNavigationRelease = await waitUntil { didSettle }
        #expect(settledBeforeNavigationRelease)
        #expect(!navigationStarted)
        navigationGate.open()
        await settle.value
        #expect(delegate.locationChangeCount == 0)
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

    @Test("mounted navigator keeps one transaction recognizer across every page-turn style")
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
        #expect(rootPanRecognizers(in: navigator).first === transactionPan)

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

    @Test("reflowable native pan guard rearms across style changes and WebKit re-enable")
    func reflowableNativePanGuardRearms() async throws {
        let navigator = try await makeMountedNavigator(pageTurnStyle: .none)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(paginationView.currentView as? EPUBReflowableSpreadView)

        spreadView.scrollView.panGestureRecognizer.isEnabled = true
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)

        navigator.pageTurnStyle = .push
        navigator.pageTurnStyle = .none
        spreadView.scrollView.panGestureRecognizer.isEnabled = true
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)

        spreadView.allowsNativeHorizontalPaging = true
        #expect(spreadView.scrollView.panGestureRecognizer.isEnabled)
        spreadView.allowsNativeHorizontalPaging = false
        spreadView.scrollView.panGestureRecognizer.isEnabled = true
        #expect(!spreadView.scrollView.panGestureRecognizer.isEnabled)
    }

    @Test("stale scroll-end callback cannot release an animated locator waiter")
    func staleScrollEndDoesNotReleaseAnimatedLocator() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spreadView = try #require(
            paginationView.currentView as? EPUBReflowableSpreadView
        )
        navigator.view.layoutIfNeeded()
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let operation = NavigationOperation(
            operationID: 900,
            intent: .absolute("animated-locator"),
            timeout: .seconds(1)
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let navigation = Task { @MainActor in
            await spreadView.go(
                to: .locator(target),
                animated: true,
                waitForLoad: true,
                operation: operation
            )
        }
        await Task.yield()
        // A delayed callback from a previous scroll has no request identity
        // and must not release this operation's executor lease.
        spreadView.scrollViewDidEndScrollingAnimation(spreadView.scrollView)
        let result = await navigation.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        #expect(result.result.isTimedOut)
        #expect(elapsed >= 900_000_000)
        #expect(spreadView.isPoisoned)
    }

    @Test("animated locator settlement requires request movement or final target geometry")
    func animatedLocatorSettlementIsRequestBound() {
        var settlement = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: .zero,
            submittedAt: 0
        )

        let initialQuiet = settlement.observe(
            offset: .zero,
            at: 300_000_000,
            targetReached: false
        )
        let staleQuiet = settlement.observe(
            offset: .zero,
            at: 900_000_000,
            targetReached: false
        )
        let moving = settlement.observe(
            offset: CGPoint(x: 120, y: 0),
            at: 1_000_000_000,
            targetReached: true
        )
        let almostQuiet = settlement.observe(
            offset: CGPoint(x: 120, y: 0),
            at: 1_299_000_000,
            targetReached: true
        )
        let settled = settlement.observe(
            offset: CGPoint(x: 120, y: 0),
            at: 1_300_000_000,
            targetReached: true
        )
        #expect(!initialQuiet)
        #expect(!staleQuiet)
        #expect(!moving)
        #expect(!almostQuiet)
        #expect(settled)

        var alreadyAtTarget = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: CGPoint(x: 120, y: 0),
            submittedAt: 0
        )
        let noOpSettled = alreadyAtTarget.observe(
            offset: CGPoint(x: 120, y: 0),
            at: 1,
            targetReached: true
        )
        #expect(noOpSettled)
    }

    @Test("adjacent page-boundary locator is not already visible so animation waits")
    func adjacentPageBoundaryLocatorDoesNotCompleteAnimationEarly() {
        let pageWidth: CGFloat = 390
        let nextPageStart = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 390,
            scrollX: 0,
            pageWidth: pageWidth
        )
        let previousPageStart = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: -390,
            scrollX: 390,
            pageWidth: pageWidth
        )
        let onCurrentPage = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 10,
            scrollX: 0,
            pageWidth: pageWidth
        )
        #expect(
            !EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 0,
                targetOffset: nextPageStart
            )
        )
        #expect(
            !EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 390,
                targetOffset: previousPageStart
            )
        )
        #expect(
            EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 0,
                targetOffset: onCurrentPage
            )
        )

        var settlement = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: .zero,
            submittedAt: 0
        )
        let premature = settlement.observe(
            offset: .zero,
            at: 1,
            targetReached: EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 0,
                targetOffset: nextPageStart
            )
        )
        #expect(!premature)

        let moving = settlement.observe(
            offset: CGPoint(x: 200, y: 0),
            at: 100_000_000,
            targetReached: false
        )
        #expect(!moving)

        let arrived = settlement.observe(
            offset: CGPoint(x: 390, y: 0),
            at: 200_000_000,
            targetReached: true
        )
        #expect(!arrived)

        let settled = settlement.observe(
            offset: CGPoint(x: 390, y: 0),
            at: 500_000_000,
            targetReached: true
        )
        #expect(settled)
    }

    @Test("spanning-column and zero-size locators compare snapped start offset")
    func spanningColumnAndZeroSizeLocatorsCompareStartOffset() {
        let pageWidth: CGFloat = 390
        let scrollX: CGFloat = 390
        let spanningTail = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: -400,
            scrollX: scrollX,
            pageWidth: pageWidth
        )
        #expect(abs(spanningTail - 0) < 0.001)
        #expect(
            !EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: scrollX,
                targetOffset: spanningTail
            )
        )

        let zeroSizeOnCurrentPage = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 0,
            scrollX: scrollX,
            pageWidth: pageWidth
        )
        #expect(
            EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: scrollX,
                targetOffset: zeroSizeOnCurrentPage
            )
        )

        let zeroSizeOnNextPage = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 390,
            scrollX: scrollX,
            pageWidth: pageWidth
        )
        #expect(
            !EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: scrollX,
                targetOffset: zeroSizeOnNextPage
            )
        )
    }

    @Test("vertical-writing DOM locators use unsnapped X instead of Y")
    func verticalWritingDOMLocatorsUseUnsnappedX() {
        let pageWidth: CGFloat = 390
        let contentWidth: CGFloat = 3900
        let targetX = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: -2145,
            scrollX: 0,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            isRTL: true,
            snapsToPage: false
        )
        #expect(abs(targetX - -2145) < 0.001)
        #expect(
            !EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 0,
                targetOffset: targetX
            )
        )

        var settlement = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: .zero,
            submittedAt: 0
        )
        let premature = settlement.observe(
            offset: .zero,
            at: 1,
            targetReached: EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 0,
                targetOffset: targetX
            )
        )
        #expect(!premature)
    }

    @Test("locator target offsets clamp to the browser-reachable scroll range")
    func locatorTargetOffsetsClampToReachableScrollRange() {
        let pageWidth: CGFloat = 390
        let contentWidth: CGFloat = 1000
        let snappedPastEnd = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 780,
            scrollX: 0,
            pageWidth: pageWidth,
            contentWidth: contentWidth
        )
        #expect(abs(snappedPastEnd - 610) < 0.001)

        let zeroSizeAtDocumentEnd = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: 1000,
            scrollX: 0,
            pageWidth: pageWidth,
            contentWidth: contentWidth
        )
        #expect(abs(zeroSizeAtDocumentEnd - 610) < 0.001)
        #expect(
            EPUBReflowableSpreadView.locatorIsAtScrollTarget(
                currentOffset: 610,
                targetOffset: zeroSizeAtDocumentEnd
            )
        )

        let rtlPastEnd = EPUBReflowableSpreadView.locatorTargetOffsetX(
            rectLeft: -780,
            scrollX: 0,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            isRTL: true
        )
        #expect(abs(rtlPastEnd - -610) < 0.001)

        let yPastEnd = EPUBReflowableSpreadView.clampScrollOffsetY(
            2000,
            pageHeight: 844,
            contentHeight: 1200
        )
        #expect(abs(yPastEnd - 356) < 0.001)
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
        #expect(rootPanRecognizers(in: navigator).count == 1)
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
            guard let paginationView = currentPaginationView(in: navigator) else {
                return false
            }
            return paginationView.axis == .verticalContinuous
                && paginationView.currentView != nil
        })
        let replacement = try #require(currentPaginationView(in: navigator))
        #expect(replacement.axis == .verticalContinuous)
        #expect(rootPanRecognizers(in: navigator).isEmpty)

        let spreadView = try #require(replacement.currentView as? EPUBSpreadView)
        try navigator.spreadView(
            spreadView,
            didFailToLoadResourceAt: #require(RelativeURL(path: "chapter.xhtml")),
            withError: .decoding("Expected test rollback")
        )

        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.axis == .horizontalPaged
                && rootPanRecognizers(in: navigator).count == 1
        })
        #expect(currentPaginationView(in: navigator)?.axis == .horizontalPaged)
        #expect(rootPanRecognizers(in: navigator).count == 1)
        navigator.handlePageTurnPanForTesting(state: .began, translationX: 0, velocityX: 700)
        #expect(!navigator.isPageTurnIdleForTesting)
        navigator.handlePageTurnPanForTesting(state: .cancelled, translationX: 0, velocityX: 0)
    }

    @Test("horizontal page-turn disables native paging for every style")
    func nativePanPolicy() {
        let policy = EPUBPageTurnInteraction.policy(axis: .horizontalPaged)
        #expect(!policy.allowsNativeHorizontalPaging)

        let continuous = EPUBPageTurnInteraction.policy(axis: .verticalContinuous)
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

        #expect(await navigator.beginCoverPageTurnForTesting(to: .right))
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

        #expect(await navigator.beginCoverPageTurnForTesting(to: .right))
        #expect(root.snapshotCount == 2)
        #expect(root.afterScreenUpdatesValues == [false, false])
        #expect(protectedSnapshots == 2)
        await navigator.settlePageTurn()
    }

    @Test("surface snapshot strategy preserves window and empty-bounds boundaries")
    func surfaceSnapshotStrategyBoundaries() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let container = UIView(frame: window.bounds)
        let onWindowRoot = SnapshotObservingView(frame: container.bounds)
        onWindowRoot.shouldFailSnapshots = true
        container.addSubview(onWindowRoot)
        window.addSubview(container)

        #expect(onWindowRoot.window === window)
        #expect(EPUBPageTurnSurfaceAnimator(
            rootView: onWindowRoot,
            style: .cover,
            physicalCompletionDirection: .left,
            isForward: true
        ) == nil)
        #expect(onWindowRoot.afterScreenUpdatesValues == [true])

        let offWindowContainer = UIView(frame: .zero)
        let emptyRoot = UIView(frame: .zero)
        offWindowContainer.addSubview(emptyRoot)
        #expect(EPUBPageTurnSurfaceAnimator(
            rootView: emptyRoot,
            style: .cover,
            physicalCompletionDirection: .left,
            isForward: true
        ) == nil)
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

        #expect(await navigator.beginCoverPageTurnForTesting(to: .right))
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
        try root.addSubview(#require(navigator?.view))
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
        navigator?.cancelOwnedNavigationWorkForTesting()
        navigator?.view.removeFromSuperview()
        navigator = nil

        #expect(await waitUntil { cancellation.value })
        #expect(await waitUntil { pageTurnSurfaces(in: container).isEmpty })
        navigationGate.open()
    }

    @Test("a display-frame wait after navigation does not retain the navigator")
    func preparedDisplayFrameWaitReleasesNavigatorAndSurface() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        container.addSubview(root)
        var loaded: (EPUBNavigatorViewController, Delegate)? =
            try await makeLoadedNavigator(pageTurnStyle: .cover)
        var navigator: EPUBNavigatorViewController? = loaded?.0
        let delegate = try #require(loaded?.1)
        loaded = nil
        navigator?.view.frame = root.bounds
        try root.addSubview(#require(navigator?.view))
        delegate.pageTurnRootView = root
        let original = try #require(navigator?.currentLocation)
        let originalViewport = try #require(navigator?.viewport)
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        let targetViewport = NavigatorViewport(
            resources: [
                .init(href: target.href, progression: 0 ... 0.25),
            ],
            progression: 0.5 ... 0.75
        )
        var previewCount = 0
        navigator?.pageTurnPreviewCalculationForTesting = {
            previewCount += 1
            return previewCount == 1
                ? (original, originalViewport)
                : (target, targetViewport)
        }
        var didNavigate = false
        navigator?.pageTurnNavigationForTesting = { _, _ in
            didNavigate = true
            return true
        }
        let displayFrameGate = Gate()
        var didReachDisplayFrame = false
        navigator?.pageTurnDisplayFrameWaiterForTesting = {
            didReachDisplayFrame = true
            await displayFrameGate.wait()
        }

        #expect(navigator?.beginPreparingPageTurnForTesting(to: .right) == true)
        #expect(await waitUntil { didNavigate && didReachDisplayFrame })
        #expect(pageTurnSurfaces(in: container).count == 1)
        weak let releasedNavigator = navigator
        navigator?.cancelOwnedNavigationWorkForTesting()
        navigator?.view.removeFromSuperview()
        navigator = nil

        #expect(pageTurnSurfaces(in: container).isEmpty)
        displayFrameGate.open()
        #expect(await waitUntil { releasedNavigator == nil })
    }

    @Test("cancelling a display-frame wait does not require a display frame")
    func cancelledDisplayFrameWaitIsLiveWithoutAFrame() async {
        let didFinish = ThreadSafeFlag()
        let task = Task { @MainActor in
            await PageTurnAnimationFrameWaiter.wait(
                scheduleDisplayFrame: { _ in }
            )
            didFinish.set()
        }
        await Task.yield()

        task.cancel()

        #expect(await waitUntil { didFinish.value })
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

    @Test("simulation keeps only directed sequential navigation animated")
    func simulationDiscreteNavigationDistinguishesSequentialTurnsFromDirectJumps() {
        let sequentialOptions = NavigatorGoOptions(
            animated: true,
            otherOptions: [
                "readium.epub.pageTurnDirection": .string("forward"),
                "probe": .string("preserved"),
            ]
        )
        let directJumpOptions = NavigatorGoOptions(
            animated: true,
            otherOptions: ["probe": .string("preserved")]
        )

        let simulation = EPUBPageTurnInteraction.discreteNavigationOptions(
            sequentialOptions,
            axis: .horizontalPaged,
            style: .simulation
        )
        let directJump = EPUBPageTurnInteraction.discreteNavigationOptions(
            directJumpOptions,
            axis: .horizontalPaged,
            style: .simulation
        )
        let push = EPUBPageTurnInteraction.discreteNavigationOptions(
            directJumpOptions,
            axis: .horizontalPaged,
            style: .push
        )
        let continuous = EPUBPageTurnInteraction.discreteNavigationOptions(
            directJumpOptions,
            axis: .verticalContinuous,
            style: .simulation
        )

        #expect(simulation == sequentialOptions)
        #expect(directJump.animated == false)
        #expect(directJump.otherOptions == directJumpOptions.otherOptions)
        #expect(push == directJumpOptions)
        #expect(continuous == directJumpOptions)
    }

    @Test("sequential chapter targets use whole-reader page-turn transactions")
    func programmaticChapterTargetsUsePageTurnSurfaces() async throws {
        for style in [EPUBPageTurnStyle.push, .cover, .simulation] {
            let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: style)
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let root = SnapshotObservingView(frame: container.bounds)
            navigator.view.frame = root.bounds
            root.addSubview(navigator.view)
            container.addSubview(root)
            delegate.pageTurnRootView = root
            delegate.pageTurnSurfaceController = makePageTurnSurfaceController(
                root: root
            )
            delegate.resetLocationChanges()
            let link = try #require(navigator.publication.readingOrder.dropFirst().first)
            let target = try #require(await navigator.publication.locate(link))
            let options = NavigatorGoOptions(
                animated: true,
                otherOptions: [
                    "readium.epub.pageTurnDirection": .string("forward"),
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

    @Test("simulation uses a curl transaction for next-page actions but not direct jumps")
    func simulationSequentialActionsCurlAndDirectJumpsStayInstant() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .simulation)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.pageTurnSurfaceController = makePageTurnSurfaceController(root: root)

        let turn = Task { @MainActor in
            await navigator.goForward(options: .animated)
        }
        #expect(await waitUntil { !pageCurlViews(in: container).isEmpty })
        #expect(await turn.value)
        await navigator.settlePageTurn()
        #expect(root.snapshotCount >= 2)

        let link = try #require(navigator.publication.readingOrder.first)
        let target = try #require(await navigator.publication.locate(link))
        let snapshotCount = root.snapshotCount
        #expect(await navigator.go(to: target, options: .animated))
        await navigator.settlePageTurn()

        #expect(root.snapshotCount == snapshotCount)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("an identity recapture failure after commit never publishes and releases the surface")
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

        #expect(await !(turn.value))
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(delegate.locationChangeCount == 0)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
        // A subsequent turn must be able to install a fresh surface.
        #expect(navigator.canBeginPageTurnPanForTesting())
    }

    @Test("accessibility cancel during identity recapture prevents irreversible commit")
    func identityRecaptureCancelDoesNotPublishTarget() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .cover,
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
        let identityGate = Gate()
        var isValidatingCommit = false
        navigator.pageTurnWillValidateCommitForTesting = { [weak navigator] in
            guard let navigator else { return }
            navigator.view.frame.origin.y = 1
            #expect(navigator.recaptureCurrentPageTurnSurfaceForTesting())
            isValidatingCommit = true
        }
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if isValidatingCommit {
                await identityGate.wait()
            }
        }

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
        #expect(await waitUntil { isValidatingCommit })

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        identityGate.open()
        await navigator.settlePageTurn()

        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("simulation commit cancellation is bounded without a display-link callback or late publish")
    func simulationCommitCancellationIsBoundedWithoutLatePublish() async throws {
        enum Cancellation {
            case background
            case style
            case reduceMotion
        }

        for cancellation in [Cancellation.background, .style, .reduceMotion] {
            let notificationCenter = NotificationCenter()
            let status = AccessibilityStatusBox()
            let (navigator, delegate) = try await makeLoadedNavigator(
                pageTurnStyle: .simulation,
                notificationCenter: notificationCenter,
                accessibilityStatus: status
            )
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let root = SnapshotObservingView(frame: container.bounds)
            navigator.view.frame = root.bounds
            root.addSubview(navigator.view)
            container.addSubview(root)
            delegate.pageTurnRootView = root
            delegate.pageTurnSurfaceController = makePageTurnSurfaceController(
                root: root
            )
            delegate.resetLocationChanges()
            let original = try #require(navigator.currentLocation)
            var scheduledFrameCount = 0
            navigator.pageTurnDisplayFrameSchedulerForTesting = { waiter in
                scheduledFrameCount += 1
                if scheduledFrameCount > 1 {
                    waiter.cancel()
                }
            }
            let commitTranslation: CGFloat = if case .background = cancellation {
                -390
            } else {
                -100
            }

            navigator.handlePageTurnPanForTesting(
                state: .began,
                translationX: 0,
                velocityX: -700
            )
            navigator.handlePageTurnPanForTesting(
                state: .ended,
                translationX: commitTranslation,
                velocityX: -700
            )
            #expect(await waitUntil {
                navigator.isPageTurnCommittingForTesting
                    && scheduledFrameCount > 0
            })

            switch cancellation {
            case .background:
                notificationCenter.post(
                    name: UIApplication.willResignActiveNotification,
                    object: nil
                )
            case .style:
                navigator.pageTurnStyle = .none
            case .reduceMotion:
                status.isReduceMotionEnabled = true
                notificationCenter.post(
                    name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                    object: nil
                )
            }

            #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
            await navigator.settlePageTurn()
            if case .background = cancellation {
                notificationCenter.post(
                    name: UIApplication.didBecomeActiveNotification,
                    object: nil
                )
            }
            try? await Task.sleep(nanoseconds: 200_000_000)

            #expect(navigator.currentLocation == original)
            #expect(delegate.locationChangeCount == 0)
            #expect(delegate.errorCount == 0)
            #expect(pageTurnSurfaces(in: container).isEmpty)
            #expect(pageCurlViews(in: container).isEmpty)
            #expect(navigator.isPageTurnIdleForTesting)
        }
    }

    @Test("push and cover commit cancellation is bounded without late publish")
    func pushAndCoverCommitCancellationIsBoundedWithoutLatePublish() async throws {
        enum Cancellation {
            case background
            case style
            case reduceMotion
        }
        let styles: [EPUBPageTurnStyle] = [.push, .cover]

        for style in styles {
            for cancellation in [Cancellation.background, .style, .reduceMotion] {
                let notificationCenter = NotificationCenter()
                let status = AccessibilityStatusBox()
                let (navigator, delegate) = try await makeLoadedNavigator(
                    pageTurnStyle: style,
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
                let original = try #require(navigator.currentLocation)
                var scheduledFrameCount = 0
                navigator.pageTurnDisplayFrameSchedulerForTesting = { waiter in
                    scheduledFrameCount += 1
                    if scheduledFrameCount > 1 {
                        waiter.cancel()
                    }
                }
                let commitTranslation: CGFloat = if case .background = cancellation {
                    -390
                } else {
                    -100
                }

                navigator.handlePageTurnPanForTesting(
                    state: .began,
                    translationX: 0,
                    velocityX: -700
                )
                navigator.handlePageTurnPanForTesting(
                    state: .ended,
                    translationX: commitTranslation,
                    velocityX: -700
                )
                #expect(await waitUntil {
                    navigator.isPageTurnCommittingForTesting
                        && scheduledFrameCount > 0
                })

                switch cancellation {
                case .background:
                    notificationCenter.post(
                        name: UIApplication.willResignActiveNotification,
                        object: nil
                    )
                case .style:
                    navigator.pageTurnStyle = .none
                case .reduceMotion:
                    status.isReduceMotionEnabled = true
                    notificationCenter.post(
                        name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                        object: nil
                    )
                }

                #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
                await navigator.settlePageTurn()
                if case .background = cancellation {
                    notificationCenter.post(
                        name: UIApplication.didBecomeActiveNotification,
                        object: nil
                    )
                }
                try? await Task.sleep(nanoseconds: 200_000_000)

                #expect(navigator.currentLocation == original)
                #expect(delegate.locationChangeCount == 0)
                #expect(delegate.errorCount == 0)
                #expect(pageTurnSurfaces(in: container).isEmpty)
                #expect(navigator.isPageTurnIdleForTesting)
            }
        }
    }

    @Test("accessibility cancel after real navigation restores the original page")
    func cancelAfterRealNavigationBeforeCaptureRestoresOriginal() async throws {
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

        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        let originalIndex = try #require(currentPaginationView(in: navigator)?.currentIndex)
        // Real navigation must run so a missed reverse-restore leaves the
        // reader on the target page (this used to pass with a no-op mock).
        var didLeaveOriginal = false
        var holdAfterNavigation = true
        navigator.pageTurnPreviewCalculationForTesting = {
            let index = currentPaginationView(in: navigator)?.currentIndex
            if index != originalIndex {
                didLeaveOriginal = true
                while holdAfterNavigation {
                    if Task.isCancelled {
                        return (nil, nil)
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return (nil, nil)
            }
            return (original, originalViewport)
        }

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
        #expect(await waitUntil { didLeaveOriginal })
        #expect(currentPaginationView(in: navigator)?.currentIndex != originalIndex)

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        holdAfterNavigation = false
        await navigator.settlePageTurn()

        #expect(currentPaginationView(in: navigator)?.currentIndex == originalIndex)
        #expect(navigator.currentLocation?.href == original.href)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("successful surface cancellation recovery is not restored a second time")
    func successfulSurfaceRecoveryPreservesStableVerification() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .push)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        var previewCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            previewCount += 1
            return previewCount == 1
                ? (original, originalViewport)
                : (target, originalViewport)
        }
        navigator.pageTurnNavigationForTesting = { _, _ in true }
        var surfaceRestoreCount = 0
        navigator.pageTurnPreparedPageRestoreForTesting = {
            surfaceRestoreCount += 1
            return true
        }
        var locatorRestoreCount = 0
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            locatorRestoreCount += 1
            return true
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
        await navigator.settlePageTurn()

        #expect(surfaceRestoreCount == 1)
        #expect(locatorRestoreCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("none commit cancellation after navigation restores original without publish")
    func noneCommitCancellationRestoresOriginalWithoutPublish() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigator.view.frame = container.bounds
        container.addSubview(navigator.view)
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalIndex = try #require(currentPaginationView(in: navigator)?.currentIndex)

        var inCommitWait = false
        var holdAfterCommitMove = true
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if navigator.isPageTurnCommittingForTesting {
                inCommitWait = true
                while holdAfterCommitMove {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }

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
        #expect(await waitUntil { inCommitWait })
        #expect(currentPaginationView(in: navigator)?.currentIndex != originalIndex)

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdAfterCommitMove = false
        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        await navigator.settlePageTurn()

        #expect(currentPaginationView(in: navigator)?.currentIndex == originalIndex)
        #expect(navigator.currentLocation?.href == original.href)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("none cancel during publish location calculation does not notify the target")
    func noneCancelDuringPublishCalculationDoesNotNotifyTarget() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigator.view.frame = container.bounds
        container.addSubview(navigator.view)
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalViewport = try #require(navigator.viewport)
        let originalIndex = try #require(currentPaginationView(in: navigator)?.currentIndex)
        let targetLink = try #require(navigator.publication.readingOrder.dropFirst().first)
        let target = try #require(await navigator.publication.locate(targetLink))

        var inPublishCalculation = false
        var holdPublishCalculation = true
        navigator.pageTurnLocationCalculationForTesting = {
            inPublishCalculation = true
            while holdPublishCalculation {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            // If cancel is ignored after this returns, the target would be published.
            return (target, originalViewport)
        }

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
        #expect(await waitUntil { inPublishCalculation })
        #expect(currentPaginationView(in: navigator)?.currentIndex != originalIndex)

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdPublishCalculation = false
        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        await navigator.settlePageTurn()

        #expect(currentPaginationView(in: navigator)?.currentIndex == originalIndex)
        #expect(navigator.currentLocation?.href == original.href)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.locations.allSatisfy { $0.href != target.href })
    }

    @Test("none cancel falls back to original locator when inverse navigation fails")
    func noneCancelFallsBackToOriginalLocatorWhenInverseFails() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigator.view.frame = container.bounds
        container.addSubview(navigator.view)
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)

        var navigationCount = 0
        var locatorRestoreCount = 0
        var restoredLocator: Locator?
        var restoreWasCancelled = false
        let restoreGate = Gate()
        var inCommitWait = false
        var holdAfterCommitMove = true
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            // First call: forward commit navigation succeeds.
            // Second call: inverse reverse fails so locator fallback must run.
            return navigationCount == 1
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            locatorRestoreCount += 1
            restoredLocator = original
            restoreWasCancelled = Task.isCancelled
            await restoreGate.wait()
            return true
        }
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if navigator.isPageTurnCommittingForTesting {
                inCommitWait = true
                while holdAfterCommitMove {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }

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
        #expect(await waitUntil { inCommitWait })
        #expect(navigationCount == 1)

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdAfterCommitMove = false
        #expect(await waitUntil { locatorRestoreCount >= 1 })
        #expect(!restoreWasCancelled)
        #expect(!navigator.isPageTurnIdleForTesting)

        restoreGate.open()
        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        await navigator.settlePageTurn()

        #expect(navigationCount >= 2)
        #expect(locatorRestoreCount >= 1)
        #expect(restoredLocator?.href == original.href)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("hard abort drains retired recovery before opening a new page-turn session")
    func hardAbortDrainsRetiredRecoveryBeforeNewSession() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let original = try #require(navigator.currentLocation)
        let restoreGate = Gate()
        var navigationCount = 0
        var didEnterRestore = false
        var inCommitWait = false
        var holdAfterCommitMove = true
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return navigationCount == 1
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            didEnterRestore = true
            await restoreGate.wait()
            return true
        }
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if navigator.isPageTurnCommittingForTesting {
                inCommitWait = true
                while holdAfterCommitMove {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }

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
        #expect(await waitUntil { inCommitWait })

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdAfterCommitMove = false
        #expect(await waitUntil { didEnterRestore })

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        var didAttemptNewSession = false
        var didOpenNewSession = false
        let newSession = Task { @MainActor in
            didAttemptNewSession = true
            didOpenNewSession = await navigator.beginPageTurnForTesting(to: .right)
            return didOpenNewSession
        }
        #expect(await waitUntil { didAttemptNewSession })
        await Task.yield()

        // The old WebView recovery still owns navigation. A new session must
        // not open until that recovery has really exited.
        #expect(!didOpenNewSession)

        restoreGate.open()
        #expect(await newSession.value)
        await Task.yield()
        #expect(!navigator.isPageTurnControllerIdleForTesting)
        #expect(navigator.currentLocation?.href == original.href)

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("locator jump waits for hard-aborted recovery and restore to drain")
    func locatorJumpWaitsForRetiredRecovery() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status,
            chapterCount: 3
        )
        let window = UIWindow(frame: navigator.view.bounds)
        window.addSubview(navigator.view)
        window.isHidden = false
        defer { window.isHidden = true }
        await nextMainRunLoop()
        let restoreGate = Gate()
        var navigationCount = 0
        var didEnterRestore = false
        var inCommitWait = false
        var holdAfterCommitMove = true
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return navigationCount == 1
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = {
            didEnterRestore = true
            await restoreGate.wait()
            return true
        }
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if navigator.isPageTurnCommittingForTesting {
                inCommitWait = true
                while holdAfterCommitMove {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }

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
        #expect(await waitUntil { inCommitWait })

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdAfterCommitMove = false
        #expect(await waitUntil { didEnterRestore })

        navigator.abortPageTurnInterruptedBySelectionForTesting(snap: false)
        let target = makeLocator(href: "chapter-3.xhtml", progression: 0)
        var didStartJump = false
        var didFinishJump = false
        let jump = Task { @MainActor in
            didStartJump = true
            let result = await navigator.go(to: target, options: .none)
            didFinishJump = true
            return result
        }
        #expect(await waitUntil { didStartJump })
        await nextMainRunLoop()

        #expect(!didFinishJump)
        #expect(currentPaginationView(in: navigator)?.currentIndex != 2)

        restoreGate.open()
        #expect(await jump.value)
        #expect(currentPaginationView(in: navigator)?.currentIndex == 2)
        await navigator.settlePageTurn()
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("clearing an unloaded fixed spread fails its pending location waiter")
    func fixedSpreadClearResumesPendingLocationWaiter() async throws {
        let navigator = try await makeMountedNavigator(
            layout: .fixed,
            pageTurnStyle: .none
        )
        let paginationView = try #require(currentPaginationView(in: navigator))
        let fixedSpread = try #require(paginationView.currentView as? EPUBFixedSpreadView)
        fixedSpread.clear()

        var didStartWaiting = false
        let navigation = Task { @MainActor in
            didStartWaiting = true
            return await fixedSpread.go(
                to: .start,
                animated: false,
                waitForLoad: true
            )
        }
        #expect(await waitUntil { didStartWaiting })
        await Task.yield()

        fixedSpread.clear()

        #expect(await !(navigation.value))
    }

    @Test("cancelling fixed spread navigation fails its pending location waiter")
    func fixedSpreadCancellationResumesPendingLocationWaiter() async throws {
        let navigator = try await makeMountedNavigator(
            layout: .fixed,
            pageTurnStyle: .none
        )
        let paginationView = try #require(currentPaginationView(in: navigator))
        let fixedSpread = try #require(paginationView.currentView as? EPUBFixedSpreadView)
        fixedSpread.clear()

        var didStartWaiting = false
        let navigation = Task { @MainActor in
            didStartWaiting = true
            return await fixedSpread.go(
                to: .start,
                animated: false,
                waitForLoad: true
            )
        }
        #expect(await waitUntil { didStartWaiting })
        await Task.yield()

        navigation.cancel()

        #expect(await !(navigation.value))
    }

    @Test("none cancel false-positive reverse still falls back to original locator")
    func noneCancelFalsePositiveReverseFallsBackToOriginalLocator() async throws {
        let notificationCenter = NotificationCenter()
        let status = AccessibilityStatusBox()
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            notificationCenter: notificationCenter,
            accessibilityStatus: status
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigator.view.frame = container.bounds
        container.addSubview(navigator.view)
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalIndex = try #require(currentPaginationView(in: navigator)?.currentIndex)

        var inCommitWait = false
        var holdAfterCommitMove = true
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if navigator.isPageTurnCommittingForTesting {
                inCommitWait = true
                while holdAfterCommitMove {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }

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
        #expect(await waitUntil { inCommitWait })
        #expect(currentPaginationView(in: navigator)?.currentIndex != originalIndex)

        // Real forward navigation already moved the page. Claim reverse success
        // without moving so a Bool-only reverse would leave the target page.
        var reverseClaimCount = 0
        navigator.pageTurnNavigationForTesting = { _, _ in
            reverseClaimCount += 1
            return true
        }

        status.isReduceMotionEnabled = true
        notificationCenter.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        holdAfterCommitMove = false
        #expect(await waitUntil { navigator.isPageTurnIdleForTesting })
        await navigator.settlePageTurn()

        #expect(reverseClaimCount >= 1)
        #expect(currentPaginationView(in: navigator)?.currentIndex == originalIndex)
        #expect(navigator.currentLocation?.href == original.href)
        #expect(delegate.locationChangeCount == 0)
        #expect(navigator.isPageTurnIdleForTesting)
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
        let window = UIWindow(frame: container.bounds)
        window.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
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

    @Test("prepare shield covers the live root until dismissed after target capture")
    func prepareShieldCoversUntilDismissed() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        container.backgroundColor = .white
        let root = UIView(frame: container.bounds)
        root.backgroundColor = .red
        container.addSubview(root)
        let animator = EPUBPageTurnSurfaceAnimator(
            rootView: root,
            style: .push,
            physicalCompletionDirection: .left,
            isForward: true
        )
        #expect(animator != nil)
        let shield = container.subviews.first {
            $0.accessibilityIdentifier == "readium.page-turn.prepare-shield"
        }
        #expect(shield != nil)
        #expect(shield?.isOpaque == true)
        #expect(shield?.isUserInteractionEnabled == false)
        // Must not use surface.* so UI probes do not treat the freeze as a turn surface.
        #expect(shield?.accessibilityIdentifier?.hasPrefix("readium.page-turn.surface.") != true)
        #expect(container.subviews.last === shield)

        root.backgroundColor = .green
        #expect(animator?.captureTarget() == true)
        #expect(container.subviews.last?.accessibilityIdentifier == "readium.page-turn.prepare-shield")

        animator?.dismissPrepareShield()
        #expect(container.subviews.contains {
            $0.accessibilityIdentifier == "readium.page-turn.prepare-shield"
        } == false)
        animator?.remove()
    }

    @Test("prepare shield frame tracks root size through recapture after layout change")
    func prepareShieldTracksRootSizeOnRecapture() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        container.backgroundColor = .white
        let root = UIView(frame: container.bounds)
        root.backgroundColor = .red
        container.addSubview(root)
        let animator = try #require(EPUBPageTurnSurfaceAnimator(
            rootView: root,
            style: .push,
            physicalCompletionDirection: .left,
            isForward: true
        ))
        let shield = try #require(container.subviews.first {
            $0.accessibilityIdentifier == "readium.page-turn.prepare-shield"
        })
        #expect(shield.frame == root.frame)

        // Simulate rotation / split-view resize mid-prepare. Without a frame
        // sync on recapture, the freeze would leave uncovered edges and the
        // live next page could flash through.
        let resized = CGRect(x: 0, y: 0, width: 320, height: 480)
        container.frame = resized
        root.frame = resized
        // Force a stale shield geometry (autoresizing may already have grown
        // it with the parent; pin it back so the recapture path is exercised).
        shield.frame = CGRect(x: 0, y: 0, width: 200, height: 400)
        #expect(shield.frame != root.frame)

        #expect(animator.recaptureCurrent())
        #expect(shield.frame == root.frame)
        #expect(container.subviews.last === shield)
        animator.remove()
    }

    @Test("whole-reader cover peels current forward and covers with target backward")
    func coverGeometry() {
        for direction in [EPUBSpreadView.Direction.left, .right] {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
            let root = UIView(frame: container.bounds)
            container.addSubview(root)
            let animator = EPUBPageTurnSurfaceAnimator(
                rootView: root,
                style: .cover,
                physicalCompletionDirection: direction,
                isForward: true
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

        for direction in [EPUBSpreadView.Direction.left, .right] {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
            let root = UIView(frame: container.bounds)
            container.addSubview(root)
            let animator = EPUBPageTurnSurfaceAnimator(
                rootView: root,
                style: .cover,
                physicalCompletionDirection: direction,
                isForward: false
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
            let expectedTargetX: CGFloat = direction == .left ? 100 : -100
            #expect(current?.transform == .identity)
            #expect(target?.transform.tx == expectedTargetX)
            if let current, let target, let parent = current.superview {
                #expect(parent.subviews.firstIndex(of: target)! > parent.subviews.firstIndex(of: current)!)
            }
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
            physicalCompletionDirection: .left,
            isForward: true
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
            physicalCompletionDirection: .left,
            isForward: true
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

    @Test("root identity detects user interface style and contrast changes")
    func rootIdentityTracksColorAppearanceTraits() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        // Force style via traitCollection override — UIKit's
        // overrideUserInterfaceStyle is not reliable for detached views in
        // this xctest host.
        let root = TraitFixedView(frame: container.bounds)
        let document = UIView(frame: CGRect(x: 0, y: 64, width: 200, height: 292))
        container.addSubview(root)
        root.addSubview(document)
        root.fixedUserInterfaceStyle = .light
        root.fixedAccessibilityContrast = .normal
        #expect(root.traitCollection.userInterfaceStyle == .light)

        let animator = try #require(EPUBPageTurnSurfaceAnimator(
            rootView: root,
            documentView: document,
            style: .cover,
            physicalCompletionDirection: .left,
            isForward: true
        ))
        #expect(animator.hasMatchingCurrentRootIdentity)

        root.fixedUserInterfaceStyle = .dark
        #expect(root.traitCollection.userInterfaceStyle == .dark)
        #expect(!animator.hasMatchingCurrentRootIdentity)

        root.fixedUserInterfaceStyle = .light
        root.fixedAccessibilityContrast = .high
        #expect(!animator.hasMatchingCurrentRootIdentity)

        #expect(animator.recaptureCurrent())
        #expect(animator.hasMatchingCurrentRootIdentity)
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
            physicalCompletionDirection: .left,
            isForward: true
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

    @Test("horizontal leading progression matches JS scrollX/scrollWidth for mid multi-page")
    func horizontalLeadingProgressionMatchesJSScrollWidth() {
        // 10 pages × 390pt: mid-resource (page 5) is offset 1950.
        let pageWidth: CGFloat = 390
        let pageCount: CGFloat = 10
        let contentWidth = pageWidth * pageCount
        let midOffset = pageWidth * 5

        let progression = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: midOffset,
            contentWidth: contentWidth
        )
        #expect(abs(progression - 0.5) < 0.000_001)

        // The incorrect (contentWidth - pageWidth) denominator overestimates
        // non-zero positions (~0.556 at mid) and must not be used for restore.
        let wrongDenominator = Double(midOffset / (contentWidth - pageWidth))
        #expect(abs(wrongDenominator - 0.5) > 0.05)
        #expect(abs(wrongDenominator - progression) > 0.05)

        // RTL / negative scrollX uses abs, matching Scripts/src/utils.js.
        let rtlProgression = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: -midOffset,
            contentWidth: contentWidth
        )
        #expect(abs(rtlProgression - 0.5) < 0.000_001)

        // End of resource: last page start is (n-1)/n, not 1.0, under scrollWidth.
        let lastPageOffset = pageWidth * (pageCount - 1)
        let lastProgression = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: lastPageOffset,
            contentWidth: contentWidth
        )
        #expect(abs(lastProgression - 0.9) < 0.000_001)
    }

    @Test("progression 1.0 matches last-page leading after JS snap and max-scroll clamp")
    func progressionOneMatchesLastPageAfterSnap() {
        let pageWidth: CGFloat = 390
        let pageCount: CGFloat = 10
        let contentWidth = pageWidth * pageCount
        let lastPageLeading = 0.9

        let reachableLTR = EPUBReflowableSpreadView.reachableHorizontalProgression(
            requested: 1,
            pageWidth: pageWidth,
            contentWidth: contentWidth
        )
        #expect(abs(reachableLTR - lastPageLeading) < 0.000_001)
        #expect(
            EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: lastPageLeading,
                requested: 1,
                pageWidth: pageWidth,
                contentWidth: contentWidth
            )
        )
        #expect(
            !EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: 0.8,
                requested: 1,
                pageWidth: pageWidth,
                contentWidth: contentWidth
            )
        )

        let lastPageOffset = -(pageWidth * (pageCount - 1))
        let liveRTL = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: lastPageOffset,
            contentWidth: contentWidth
        )
        let reachableRTL = EPUBReflowableSpreadView.reachableHorizontalProgression(
            requested: 1,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            isRTL: true
        )
        #expect(abs(liveRTL - lastPageLeading) < 0.000_001)
        #expect(abs(reachableRTL - lastPageLeading) < 0.000_001)
        #expect(
            EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: liveRTL,
                requested: 1,
                pageWidth: pageWidth,
                contentWidth: contentWidth,
                isRTL: true
            )
        )

        var alreadyAtEnd = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: CGPoint(x: pageWidth * (pageCount - 1), y: 0),
            submittedAt: 0
        )
        let noOpAtEnd = alreadyAtEnd.observe(
            offset: CGPoint(x: pageWidth * (pageCount - 1), y: 0),
            at: 1,
            targetReached: EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: lastPageLeading,
                requested: 1,
                pageWidth: pageWidth,
                contentWidth: contentWidth
            )
        )
        #expect(noOpAtEnd)

        var animatingToEnd = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: .zero,
            submittedAt: 0
        )
        let notYetAtEnd = animatingToEnd.observe(
            offset: .zero,
            at: 1,
            targetReached: EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: 0,
                requested: 1,
                pageWidth: pageWidth,
                contentWidth: contentWidth
            )
        )
        let arrivingAtEnd = animatingToEnd.observe(
            offset: CGPoint(x: pageWidth * (pageCount - 1), y: 0),
            at: 100_000_000,
            targetReached: true
        )
        let settledAtEnd = animatingToEnd.observe(
            offset: CGPoint(x: pageWidth * (pageCount - 1), y: 0),
            at: 400_000_000,
            targetReached: true
        )
        #expect(!notYetAtEnd)
        #expect(!arrivingAtEnd)
        #expect(settledAtEnd)
    }

    @Test("vertical-text scroll does not snap progression and uses pixel settlement")
    func verticalTextScrollDoesNotSnapProgression() {
        let pageWidth: CGFloat = 390
        let contentWidth: CGFloat = 3900
        let requested = 0.55
        let snappedNeighbor = 0.5

        let unsnapped = EPUBReflowableSpreadView.reachableHorizontalProgression(
            requested: requested,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            snapsToPage: false
        )
        #expect(abs(unsnapped - requested) < 0.000_001)
        #expect(
            !EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: snappedNeighbor,
                requested: requested,
                pageWidth: pageWidth,
                contentWidth: contentWidth,
                snapsToPage: false
            )
        )
        #expect(
            EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: requested,
                requested: requested,
                pageWidth: pageWidth,
                contentWidth: contentWidth,
                snapsToPage: false
            )
        )

        let snapped = EPUBReflowableSpreadView.reachableHorizontalProgression(
            requested: requested,
            pageWidth: pageWidth,
            contentWidth: contentWidth,
            snapsToPage: true
        )
        #expect(abs(snapped - snappedNeighbor) < 0.000_001)

        var prematureWait = EPUBReflowableSpreadView.ScrollAnimationSettlement(
            initialOffset: CGPoint(x: -pageWidth * 5, y: 0),
            submittedAt: 0
        )
        let premature = prematureWait.observe(
            offset: CGPoint(x: -pageWidth * 5, y: 0),
            at: 1,
            targetReached: EPUBReflowableSpreadView.isAtHorizontalProgression(
                live: snappedNeighbor,
                requested: requested,
                pageWidth: pageWidth,
                contentWidth: contentWidth,
                snapsToPage: false
            )
        )
        #expect(!premature)
    }

    @Test("same-resource mid progression restore rejects false-positive reverse")
    func sameResourceMidProgressionRestoreRejectsFalsePositiveReverse() async {
        // Models 10-page resource at ~50%: inverse "succeeds" but leaves the
        // live progression on a neighboring page → locator restore must run.
        let pageWidth: CGFloat = 390
        let contentWidth = pageWidth * 10
        let originalOffset = pageWidth * 5 // 50%
        let wrongOffset = pageWidth * 6 // false-positive reverse landing

        let originalProgression = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: originalOffset,
            contentWidth: contentWidth
        )
        let wrongProgression = EPUBReflowableSpreadView.leadingProgression(
            contentOffsetX: wrongOffset,
            contentWidth: contentWidth
        )
        #expect(abs(originalProgression - 0.5) < 0.000_001)
        #expect(abs(wrongProgression - originalProgression) > 0.05)

        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var liveProgression = wrongProgression
        var originalRestoreCount = 0

        let restored = await controller.restorePreparedPage(
            inverse: {
                // Claims success without correcting progression.
                true
            },
            validateOriginalLocation: {
                abs(liveProgression - originalProgression) <= 0.001
            },
            originalLocation: {
                originalRestoreCount += 1
                liveProgression = originalProgression
                return true
            }
        )

        #expect(restored)
        #expect(originalRestoreCount == 1)
        #expect(abs(liveProgression - 0.5) < 0.000_001)
    }

    @Test("same-resource multi-column cancel recovery uses live scroll progression")
    func sameResourceMultiColumnCancelRecoveryUsesLiveScrollProgression() async throws {
        // Exercises isLiveViewAtPageTurnOriginalLocator's multi-column branch and
        // the cancel restorePreparedPage path. Geometry is injected via the
        // testing hook because headless WKWebView resets forced contentSize
        // across await suspension points.
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}

        let pageWidth: CGFloat = 390
        let pageCount = 10
        let originalPage = 5
        let wrongPage = 6
        let originalProgression = Double(originalPage) / Double(pageCount)
        let wrongProgression = Double(wrongPage) / Double(pageCount)
        let original = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: originalProgression)
        )

        func setLiveColumn(progression: Double) {
            navigator.pageTurnMultiColumnGeometryForTesting = (
                pageWidth: pageWidth,
                contentWidth: pageWidth * CGFloat(pageCount),
                progression: progression
            )
        }

        setLiveColumn(progression: originalProgression)
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original))

        // False-positive reverse: same resource, neighboring column.
        setLiveColumn(progression: wrongProgression)
        #expect(abs(wrongProgression - originalProgression) > 0.05)
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original)))

        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var restoreCount = 0
        let restored = await controller.restorePreparedPage(
            inverse: { true },
            validateOriginalLocation: {
                await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original)
            },
            originalLocation: {
                restoreCount += 1
                setLiveColumn(progression: originalProgression)
                return true
            }
        )

        #expect(restored)
        #expect(restoreCount == 1)
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original))
        #expect(
            abs(
                (navigator.pageTurnMultiColumnGeometryForTesting?.progression ?? -1)
                    - originalProgression
            ) < 0.001
        )
    }

    @Test("locator navigation verifies the live resource-local progression")
    func locatorNavigationVerifiesLiveProgression() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.5)
        )
        let operation = NavigationOperation(
            operationID: 42,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.7
        )
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied == false)

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.54
        )
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied)
    }

    @Test("progression 1.0 verifies against the last page in a multi-page resource")
    func progressionOneVerifiesAgainstLastPage() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 1)
        )
        let operation = NavigationOperation(
            operationID: 43,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.9
        )
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(target))
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied)

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(target)))
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied == false)
    }

    @Test("unsnapped vertical-text progression 0.55 does not match neighboring page 0.50")
    func unsnappedVerticalTextProgressionDoesNotMatchNeighborPage() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnSnapsToPageForTesting = false
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.55)
        )
        let operation = NavigationOperation(
            operationID: 44,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.5
        )
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(target)))
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied == false)

        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.55
        )
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(target))
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            target,
            operation: operation
        )).isApplied)
    }

    @Test("cssSelector locators navigate via scrollToLocator even with progression")
    func cssSelectorLocatorsPreferDOMNavigation() {
        let href = AnyURL(string: "chapter-1.xhtml")!
        let selectorOnly = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(otherLocations: ["cssSelector": .string("#target")])
        )
        let selectorAndProgression = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                progression: 0,
                otherLocations: ["cssSelector": .string("#target")]
            )
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: selectorOnly) == .locator
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: selectorAndProgression)
                == .locator
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(
                for: Locator(
                    href: href,
                    mediaType: .xhtml,
                    locations: .init(),
                    text: .init(highlight: "quoted")
                )
            ) == .locator
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(
                for: Locator(
                    href: href,
                    mediaType: .xhtml,
                    locations: .init(fragments: ["target"], progression: 0.2)
                )
            ) == .fragment("target")
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(
                for: Locator(
                    href: href,
                    mediaType: .xhtml,
                    locations: .init(progression: 0.4)
                )
            ) == .progression(0.4)
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(
                for: Locator(
                    href: href,
                    mediaType: .xhtml,
                    locations: .init(position: 4)
                )
            ) == .unresolvedPosition
        )
    }

    @Test("absolute navigation resolves position-only locators before goToIndex")
    func absoluteNavigationResolvesPositionOnlyLocators() async throws {
        let positionsPerResource = 10
        let positions: [[Locator]] = [
            (0 ..< positionsPerResource).map { index in
                Locator(
                    href: AnyURL(string: "chapter-1.xhtml")!,
                    mediaType: .xhtml,
                    locations: .init(
                        progression: Double(index) / Double(positionsPerResource - 1),
                        position: index + 1
                    )
                )
            },
        ]
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1,
            positionsByReadingOrder: positions
        )
        let positionOnly = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(position: 6)
        )
        let resolved = navigator.resolveLocatorProgressionForTesting(positionOnly)
        #expect(resolved?.locations.position == 6)
        #expect(resolved?.locations.progression == 5.0 / 9.0)
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: resolved!)
                == .progression(5.0 / 9.0)
        )
    }

    @Test("position resolution merges progression without replacing precise targets")
    func positionResolutionPreservesCombinedLocatorTargets() async throws {
        let href = AnyURL(string: "chapter-1.xhtml")!
        let positions: [[Locator]] = [
            [
                Locator(
                    href: href,
                    mediaType: .xhtml,
                    title: "Positions title",
                    locations: .init(progression: 0.5, position: 6)
                ),
            ],
        ]
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1,
            positionsByReadingOrder: positions
        )

        let withFragment = Locator(
            href: href,
            mediaType: .xhtml,
            title: "Caller title",
            locations: .init(fragments: ["note-3"], position: 6),
            text: .init(highlight: "quoted")
        )
        let resolvedFragment = navigator.resolveLocatorProgressionForTesting(withFragment)
        #expect(resolvedFragment?.title == "Caller title")
        #expect(resolvedFragment?.locations.fragments == ["note-3"])
        #expect(resolvedFragment?.locations.position == 6)
        #expect(resolvedFragment?.locations.progression == nil)
        #expect(resolvedFragment?.text.highlight == "quoted")
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: resolvedFragment!)
                == .locator
        )

        let withSelector = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                position: 6,
                otherLocations: ["cssSelector": .string("#note-3")]
            )
        )
        let resolvedSelector = navigator.resolveLocatorProgressionForTesting(withSelector)
        #expect(resolvedSelector?.locations.cssSelector == "#note-3")
        #expect(resolvedSelector?.locations.progression == nil)
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: resolvedSelector!)
                == .locator
        )

        let fragmentOnly = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(fragments: ["note-3"], position: 6)
        )
        let resolvedFragmentOnly = navigator.resolveLocatorProgressionForTesting(fragmentOnly)
        #expect(resolvedFragmentOnly?.locations.fragments == ["note-3"])
        #expect(resolvedFragmentOnly?.locations.progression == nil)
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: resolvedFragmentOnly!)
                == .fragment("note-3")
        )
    }

    @Test("fragment IDs are encoded as JSON string literals for JavaScript")
    func fragmentIDsAreJSONEncodedForJavaScript() {
        #expect(EPUBReflowableSpreadView.javaScriptStringLiteral("heading") == "\"heading\"")
        #expect(
            EPUBReflowableSpreadView.javaScriptStringLiteral("it's\\id")
                == "\"it's\\\\id\""
        )
        #expect(
            EPUBReflowableSpreadView.javaScriptStringLiteral("line\nbreak")
                == "\"line\\nbreak\""
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(
                for: Locator(
                    href: AnyURL(string: "chapter-1.xhtml")!,
                    mediaType: .xhtml,
                    locations: .init(fragments: ["it's\\id"])
                )
            ) == .fragment("it's\\id")
        )
    }

    @Test("position-only locator without positions data fails instead of scrolling to 0")
    func positionOnlyLocatorWithoutPositionsFailsClosed() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let positionOnly = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(position: 4)
        )
        #expect(navigator.resolveLocatorProgressionForTesting(positionOnly) == nil)
        let operation = NavigationOperation(
            operationID: 45,
            intent: .absolute(positionOnly.href.string),
            timeout: .seconds(1)
        )
        #expect(await (navigator.verifyLocatorNavigationForTesting(
            positionOnly,
            operation: operation
        )).isApplied == false)

        let didNavigate = await navigator.go(to: positionOnly, options: .init(animated: false))
        #expect(!didNavigate)
    }

    @Test("DOM locators with position still navigate when positions data is missing")
    func domLocatorsWithPositionDoNotRequirePositionsData() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let href = AnyURL(string: "chapter-1.xhtml")!
        let withFragment = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(fragments: ["note-3"], position: 6)
        )
        let withSelector = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                position: 6,
                otherLocations: ["cssSelector": .string("#note-3")]
            )
        )
        let withText = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(position: 6),
            text: .init(highlight: "quoted")
        )
        #expect(navigator.resolveLocatorProgressionForTesting(withFragment)?.locations.fragments == ["note-3"])
        #expect(navigator.resolveLocatorProgressionForTesting(withSelector)?.locations.cssSelector == "#note-3")
        #expect(navigator.resolveLocatorProgressionForTesting(withText)?.text.highlight == "quoted")
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: withFragment)
                == .fragment("note-3")
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: withSelector) == .locator
        )
        #expect(
            EPUBReflowableSpreadView.reflowableNavigationTarget(for: withText) == .locator
        )
    }

    @Test("failed locator verification restores the stable location before releasing")
    func failedLocatorVerificationRestoresStableLocation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.2
        )
        var restored: Locator?
        navigator.pageTurnRestoreGoForTesting = { locator in
            restored = locator
            return true
        }
        let stable = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.1)
        )
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let operation = NavigationOperation(
            operationID: 46,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )
        let result = await navigator.performLocatorNavigationMutationForTesting(
            to: target,
            operation: operation,
            stableLocator: stable
        )
        #expect(result.result.isApplied == false)
        #expect(result.mayHaveMutated)
        #expect(result.stableLocator == stable)
        #expect(!result.stableVerified)
        #expect(result.failureStage == .verification)
        #expect(restored?.locations.progression == 0.1)
        #expect(delegate.jumpCount == 0)
    }

    @Test("successful locator verification sends didJumpTo once")
    func successfulLocatorVerificationSendsDidJumpToOnce() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let operation = NavigationOperation(
            operationID: 47,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )
        let result = await navigator.performLocatorNavigationForTesting(
            to: target,
            operation: operation,
            stableLocator: target
        )
        #expect(result.isApplied)
        #expect(delegate.jumpCount == 1)
        #expect(delegate.jumpedLocators.first?.locations.progression == 0.8)
    }

    @Test("navigate exposes applied only after verified locator publication")
    func navigateExposesAppliedAfterVerifiedLocatorPublication() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        var mutationTarget: Locator?
        navigator.pageTurnGoToIndexForTesting = { locator in
            mutationTarget = locator
            return .applied
        }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8),
            text: .init(highlight: "Page")
        )
        navigator.locatorNavigationDOMTargetVerifierForTesting = { locator in
            locator == target
        }

        let outcome = await navigator.navigate(
            to: target,
            options: .init(animated: false)
        )

        #expect(outcome == .applied)
        #expect(mutationTarget == target)
        #expect(delegate.jumpedLocators == [target])
    }

    @Test("legacy locator go remains a Bool applied wrapper")
    func legacyLocatorGoRemainsBoolAppliedWrapper() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )

        #expect(await navigator.go(to: target, options: .init(animated: false)))
    }

    @Test("goToIndex timeout after mutation still restores the stable locator")
    func goToIndexTimeoutAfterMutationStillRestores() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .timedOut }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        var restored: Locator?
        navigator.pageTurnRestoreGoForTesting = { locator in
            restored = locator
            navigator.pageTurnMultiColumnGeometryForTesting = (
                pageWidth: 390,
                contentWidth: 3900,
                progression: locator.locations.progression ?? 0
            )
            return true
        }
        let stable = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.1)
        )
        navigator.pageTurnLocationCalculationForTesting = {
            (stable, nil)
        }
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let operation = NavigationOperation(
            operationID: 48,
            intent: .absolute(target.href.string),
            timeout: .seconds(1)
        )
        let result = await navigator.performLocatorNavigationForTesting(
            to: target,
            operation: operation,
            stableLocator: stable
        )
        #expect(result.isTimedOut)
        #expect(restored?.locations.progression == 0.1)
        #expect(delegate.jumpCount == 0)
        #expect(navigator.currentLocation?.locations.progression == 0.1)
    }

    @Test("expired operation restore keeps the executor-owned token")
    func expiredOperationRestoreKeepsExecutorToken() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let operation = NavigationOperation(
            operationID: 49,
            intent: .absolute("chapter-1.xhtml"),
            timeout: .milliseconds(1)
        )
        navigator.pageTurnGoToIndexForTesting = { _ in
            try? await Task.sleep(nanoseconds: 2_000_000)
            return .timedOut
        }
        var restored: Locator?
        navigator.pageTurnRestoreGoToIndexForTesting = { locator in
            restored = locator
            return true
        }
        let stable = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.1)
        )
        let target = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let result = await navigator.performLocatorNavigationForTesting(
            to: target,
            operation: operation,
            stableLocator: stable
        )
        #expect(result.isTimedOut)
        #expect(restored?.locations.progression == 0.1)
        #expect(navigator.pageTurnRestoreUsedOperationTokenForTesting == true)
        #expect(operation.check()?.isTimedOut == true)
    }

    @Test("unresolvable poison recovery locator fails closed instead of reloading the start")
    func unresolvablePoisonRecoveryLocatorFailsClosed() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 2
        )
        let positionOnly = Locator(
            href: AnyURL(string: "chapter-2.xhtml")!,
            mediaType: .xhtml,
            locations: .init(position: 8)
        )
        let operation = NavigationOperation(
            operationID: 50,
            intent: .reload("poison"),
            timeout: .seconds(1)
        )
        let result = await navigator.replacePoisonedPaginationForTesting(
            stableLocator: positionOnly,
            operation: operation
        )
        #expect(result.isApplied == false)
        #expect(navigator.pageTurnPoisonReloadLocatorForTesting == nil)
    }

    @Test("position-only multi-column locator rejects same-resource wrong column")
    func positionOnlyMultiColumnLocatorRejectsSameResourceWrongColumn() async throws {
        let positionsPerResource = 10
        let positions: [[Locator]] = [
            (0 ..< positionsPerResource).map { index in
                Locator(
                    href: AnyURL(string: "chapter-1.xhtml")!,
                    mediaType: .xhtml,
                    locations: .init(
                        progression: Double(index) / Double(positionsPerResource - 1),
                        position: index + 1
                    )
                )
            },
        ]
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1,
            positionsByReadingOrder: positions
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}

        let pageWidth: CGFloat = 390
        let originalPage = 5
        let wrongPage = 6
        // Position mapping uses ceil(progression * (count - 1)).
        let originalProgression = Double(originalPage) / Double(positionsPerResource - 1)
        let wrongProgression = Double(wrongPage) / Double(positionsPerResource - 1)
        let originalPosition = originalPage + 1
        let positionOnly = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(position: originalPosition)
        )

        func setLiveColumn(progression: Double) {
            navigator.pageTurnMultiColumnGeometryForTesting = (
                pageWidth: pageWidth,
                contentWidth: pageWidth * CGFloat(positionsPerResource),
                progression: progression
            )
        }

        // position → progression resolution used by restorePageTurnLocator.
        let resolved = navigator.resolvePageTurnLocatorForRestoreForTesting(positionOnly)
        #expect(resolved.locations.position == originalPosition)
        #expect(resolved.locations.progression == originalProgression)

        setLiveColumn(progression: originalProgression)
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(positionOnly))

        setLiveColumn(progression: wrongProgression)
        // Pre-fix bug: resource match alone returned true and skipped restore.
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(positionOnly)))

        // Observes the locator after position→progression resolution, without
        // hanging on headless WebKit goToIndex.
        var restoredGoLocator: Locator?
        navigator.pageTurnRestoreGoForTesting = { locator in
            restoredGoLocator = locator
            setLiveColumn(progression: locator.locations.progression ?? -1)
            return true
        }

        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        var restoreCount = 0
        let restored = await controller.restorePreparedPage(
            inverse: { true },
            validateOriginalLocation: {
                await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(positionOnly)
            },
            originalLocation: {
                restoreCount += 1
                // Real restorePageTurnLocator path: resolve then go (hooked).
                return await navigator.restorePageTurnLocatorForTesting(positionOnly)
            }
        )
        #expect(restored)
        #expect(restoreCount == 1)
        #expect(restoredGoLocator?.locations.position == originalPosition)
        #expect(restoredGoLocator?.locations.progression == originalProgression)
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(positionOnly))
    }

    @Test("zero-size reflowable layout fails closed instead of single-page success")
    func zeroSizeReflowableLayoutFailsClosedInsteadOfSinglePageSuccess() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        var frameWaits = 0
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            frameWaits += 1
        }

        let original = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.5)
        )

        // pageWidth == 0: cold/reload first frame — must not count as single-page success.
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 0,
            contentWidth: 3900,
            progression: 0.6
        )
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original)))
        #expect(frameWaits >= 1)

        frameWaits = 0
        // contentWidth == 0 is the same unusable layout state.
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 0,
            progression: 0.6
        )
        #expect(await !(navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original)))
        #expect(frameWaits >= 1)

        // Valid single-page geometry still succeeds on resource match alone.
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original))
    }

    @Test("single-width vertical locator verification uses the outer pagination offset")
    func singleWidthVerticalLocatorUsesOuterPaginationOffset() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let original = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.5)
        )
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        navigator.pageTurnVerticalLocationVerifierForTesting = { _, _ in false }

        #expect(await !navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original))

        navigator.pageTurnVerticalLocationVerifierForTesting = { _, _ in true }
        #expect(await navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(original))
    }

    @Test("operation-aware vertical verification rejects an applied false value")
    func operationAwareVerticalVerificationRejectsFalse() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let original = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.5)
        )
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        navigator.pageTurnVerticalLocationVerifierForTesting = { _, _ in false }
        let operation = NavigationOperation(
            operationID: 801,
            intent: .absolute("vertical-verification"),
            timeout: .seconds(1)
        )

        #expect(await !navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(
            original,
            operation: operation
        ))
    }

    @Test("single-width vertical DOM locators use the outer pagination offset")
    func singleWidthVerticalDOMLocatorsUseOuterPaginationOffset() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 390,
            progression: 0
        )
        var verifiedLocations: [PageLocation] = []
        navigator.pageTurnVerticalLocationVerifierForTesting = { location, _ in
            verifiedLocations.append(location)
            return false
        }
        let href = AnyURL(string: "chapter-1.xhtml")!
        let locators = [
            Locator(
                href: href,
                mediaType: .xhtml,
                locations: .init(fragments: ["target"])
            ),
            Locator(
                href: href,
                mediaType: .xhtml,
                locations: .init(otherLocations: ["cssSelector": .string("#target")])
            ),
            Locator(
                href: href,
                mediaType: .xhtml,
                locations: .init(),
                text: .init(highlight: "Target text")
            ),
        ]

        for locator in locators {
            #expect(await !navigator.isLiveViewAtPageTurnOriginalLocatorForTesting(locator))
        }
        #expect(verifiedLocations.count == 3)
    }

    @Test("expired recovery leaves poisoned pagination for the next executor operation")
    func expiredRecoveryLeavesPoisonedPaginationDeferred() async throws {
        let (navigator, _) = try await makeLoadedNavigator(pageTurnStyle: .none)
        let window = UIWindow(frame: navigator.view.bounds)
        window.addSubview(navigator.view)
        window.isHidden = false
        defer { window.isHidden = true }
        await nextMainRunLoop()
        let paginationView = try #require(currentPaginationView(in: navigator))
        let originalSpread = try #require(paginationView.currentView as? EPUBSpreadView)
        originalSpread.poison(with: .timedOut)
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(1))

        let result = await navigator.goForward(options: .none)

        #expect(!result)
        #expect(paginationView.loadedViews.isEmpty)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(paginationView.loadedViews.isEmpty)

        navigator.setNavigationOperationTimeoutForTesting(.seconds(15))
        #expect(await navigator.goForward(options: .none))
        #expect(!paginationView.loadedViews.isEmpty)
    }

    @Test("poison recovery rebinds the operation to the replacement pagination generation")
    func poisonRecoveryRebindsOperationToReplacementPaginationGeneration() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 2
        )
        let window = UIWindow(frame: navigator.view.bounds)
        window.addSubview(navigator.view)
        window.isHidden = false
        defer { window.isHidden = true }
        await nextMainRunLoop()

        let paginationView = try #require(currentPaginationView(in: navigator))
        let stableLocator = try #require(navigator.currentLocation)
        let currentSpread = try #require(paginationView.currentView as? EPUBSpreadView)
        let originalGeneration = paginationView.generation
        let operation = NavigationOperation(
            operationID: 51,
            intent: .reload("poison-recovery"),
            timeout: .seconds(15)
        )
        operation.bindPaginationGeneration(originalGeneration)

        currentSpread.poison(with: .webContentTerminated)
        paginationView.isolateForDeferredReload(with: .webContentTerminated)
        operation.beginRecovery()

        #expect(paginationView.generation > originalGeneration)
        let result = await navigator.replacePoisonedPaginationForTesting(
            stableLocator: stableLocator,
            operation: operation
        )

        #expect(result.isApplied)
        #expect(paginationView.currentIndex == 0)
        #expect(paginationView.loadedViews[0] != nil)
    }

    @Test("timeout isolation preserves the exact original surface preview")
    func timeoutIsolationPreservesExactOriginalPreview() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .cover,
            chapterHTML: "<html><body><p id=\"exact-original\">Page</p></body></html>"
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        let viewport = try #require(navigator.viewport)
        let exactOriginal = Locator(
            href: AnyURL(string: "chapter-1.xhtml")!,
            mediaType: .xhtml,
            locations: .init(otherLocations: [
                "cssSelector": .string("#exact-original"),
            ])
        )
        let target = makeLocator(href: "chapter-2.xhtml", progression: 0)
        var previewCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            previewCount += 1
            return previewCount == 1
                ? (exactOriginal, viewport)
                : (target, viewport)
        }
        let navigationGate = Gate()
        var navigationStarted = false
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationStarted = true
            await navigationGate.wait()
            return false
        }
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(500))

        let first = Task { @MainActor in
            await navigator.goForward(options: .animated)
        }
        #expect(await waitUntil { navigationStarted })
        #expect(await !first.value)
        navigationGate.open()
        try? await Task.sleep(nanoseconds: 20_000_000)

        navigator.setNavigationOperationTimeoutForTesting(.seconds(15))
        navigator.pageTurnStyle = .none
        _ = await navigator.goForward(options: .none)

        #expect(
            navigator.pageTurnPoisonReloadLocatorForTesting?.locations.cssSelector
                == "#exact-original"
        )
    }

    @Test("failed surface prepare after navigation does not navigate again on commit")
    func failedSurfacePrepareAfterNavigationDoesNotAdvanceAgain() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .push,
            chapterCount: 3
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        #expect(await navigator.goForward(options: .none))
        await navigator.settlePageTurn()
        delegate.resetLocationChanges()
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))

        // Prepare installs with the first snapshot, then pretends under-surface
        // navigation succeeded. Fail every later snapshot so target capture
        // fails → didPrepareTarget == true, isPrepared == false. Commit must
        // publish only and must not call navigation a second time.
        var navigationCount = 0
        navigator.pageTurnNavigationForTesting = { _, _ in
            navigationCount += 1
            return true
        }
        root.onSnapshot = {
            // After the install snapshot succeeds, fail subsequent captures.
            if root.snapshotCount >= 2 {
                root.shouldFailSnapshots = true
            }
        }

        _ = await navigator.goForward(options: .animated)
        await navigator.settlePageTurn()

        // Prepare may navigate once under the surface; commit after a failed
        // prepare must not issue a second navigation (no chapter-4 overshoot).
        #expect(navigationCount <= 1)
        #expect(
            navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml")
                || navigator.currentLocation?.href == AnyURL(string: "chapter-3.xhtml")
        )
        #expect(navigator.currentLocation?.href != AnyURL(string: "chapter-4.xhtml"))
        #expect(navigator.isPageTurnIdleForTesting)
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
        #expect(await navigator.beginPageTurnForTesting(to: .right))
        spread.updateActiveMediaState(document: "same-url:first", isActive: true)
        #expect(navigator.snapshotProvider.revision == revision + 1)
        #expect(navigator.snapshotProvider.cachedSnapshot(for: target) == nil)
        #expect(await navigator.beginPageTurnForTesting(to: .left))

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
            #expect(await navigator.beginCoverPageTurnForTesting(to: .right))
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

    @Test("retired cover restoration cannot clean up or finish after hard abort")
    func retiredCoverRestoreDoesNotMutateController() async throws {
        let controller = EPUBPageTurnController(refreshCurrentLocation: {})
        let session = try #require(controller.begin(to: .right, readingProgression: .ltr))
        let reboundGate = Gate()
        var didEnterRebound = false
        var cleanupCount = 0
        var finishCount = 0

        let restore = Task { @MainActor in
            await controller.restoreCover(
                session,
                rebound: { _ in
                    didEnterRebound = true
                    await reboundGate.wait()
                    return true
                },
                cleanup: { cleanupCount += 1 },
                finish: { _ in finishCount += 1 }
            )
        }
        #expect(await waitUntil { didEnterRebound })

        // Models hardAbortInFlightPageTurn retiring the active session while
        // an independent WebView recovery is suspended.
        #expect(controller.finish(session))
        reboundGate.open()

        #expect(await restore.value == false)
        #expect(cleanupCount == 0)
        #expect(finishCount == 0)
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
                .init(href: oldLocation.href, progression: 0 ... 0.25),
            ],
            progression: 0 ... 0.25
        )
        let rejectedViewport = NavigatorViewport(
            resources: [
                .init(
                    href: AnyURL(string: "rejected.xhtml")!,
                    progression: 0.5 ... 0.75
                ),
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

    @Test("missing original preview degrades a committed turn to instant navigation")
    func missingOriginalPreviewDegradesToInstantNavigation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        let original = try #require(navigator.currentLocation)
        let originalIndex = try #require(currentPaginationView(in: navigator)?.currentIndex)
        navigator.pageTurnPreviewCalculationForTesting = { (nil, nil) }

        #expect(await navigator.goForward(options: .animated))
        await navigator.settlePageTurn()

        #expect(currentPaginationView(in: navigator)?.currentIndex == originalIndex + 1)
        #expect(root.snapshotCount == 1)
        #expect(delegate.locationChangeCount == 1)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(navigator.currentLocation != original)
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
                .init(href: target.href, progression: 0 ... 0.25),
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

    @Test("target preview settles to the live page identity before capture")
    func targetPreviewSettlesBeforeCapture() async throws {
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
        let earlyTarget = makeLocator(href: "chapter-2.xhtml", progression: 0)
        let settledTarget = makeLocator(href: "chapter-2.xhtml", progression: 0.2)
        let targetViewport = NavigatorViewport(
            resources: [
                .init(href: settledTarget.href, progression: 0.2 ... 0.4),
            ],
            progression: 0.2 ... 0.4
        )
        var calculationCount = 0
        navigator.pageTurnPreviewCalculationForTesting = {
            calculationCount += 1
            switch calculationCount {
            case 1:
                return (original, originalViewport)
            case 2:
                return (earlyTarget, targetViewport)
            default:
                return (settledTarget, targetViewport)
            }
        }
        navigator.pageTurnNavigationForTesting = { _, _ in true }
        navigator.pageTurnLocationCalculationForTesting = {
            (settledTarget, targetViewport)
        }

        #expect(await navigator.goForward(options: .animated))

        #expect(calculationCount >= 4)
        #expect(delegate.previews.contains { $0.0 == settledTarget })
        #expect(navigator.currentLocation == settledTarget)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("missing target preview degrades a committed turn without a surface")
    func missingTargetPreviewDegradesWithoutSurface() async throws {
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

        #expect(await navigator.goForward(options: .animated))
        await navigator.settlePageTurn()

        #expect(calculationCount >= 2)
        #expect(root.snapshotCount == 1)
        #expect(currentPaginationView(in: navigator)?.currentIndex == 1)
        #expect(delegate.locationChangeCount == 1)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(navigator.currentLocation != original)
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
                .init(href: target.href, progression: 0 ... 0.25),
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
            if root.snapshotCount >= 2 {
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

        #expect(await !(turn.value))
        await navigator.settlePageTurn()

        #expect(frameCount >= 4)
        #expect(delegate.previews.count >= 3)
        #expect(delegate.previews.dropLast().last?.0 == original)
        #expect(delegate.previews.last?.0 == nil)
        #expect(recapturedAfterOriginalPreview)
        #expect(delegate.locationChangeCount == 0)
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("gesture restoration exhaustion never publishes the cancelled target")
    func gestureRestoreFailureDoesNotPublishTarget() async throws {
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

        #expect(await waitUntil { navigator.isPageTurnControllerIdleForTesting })
        #expect(navigationCount == 3)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.previews.last?.0 == nil)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
    }

    @Test("unrestorable cancellation reloads the saved original locator and releases input")
    func unrecoverableCancellationReloadsOriginalLocation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        let original = try #require(navigator.currentLocation)
        delegate.resetLocationChanges()
        var preparedRestoreAttempts = 0
        navigator.pageTurnPreparedPageRestoreForTesting = {
            preparedRestoreAttempts += 1
            return false
        }
        navigator.pageTurnOriginalLocationRestoreForTesting = { false }

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )
        #expect(await waitUntil {
            currentPaginationView(in: navigator)?.currentIndex == 1
                && navigator.pageTurnSurfaceTransactionEvidenceForTesting.hasPreparedTarget
        })
        navigator.handlePageTurnPanForTesting(
            state: .cancelled,
            translationX: 0,
            velocityX: 0
        )
        await navigator.settlePageTurn()

        #expect(preparedRestoreAttempts >= 2)
        #expect(currentPaginationView(in: navigator)?.currentIndex == 0)
        #expect(navigator.currentLocation == original)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.previews.dropLast().last?.0 == original)
        #expect(delegate.previews.last?.0 == nil)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.canBeginPageTurnPanForTesting())
    }

    @Test("missing page root degrades committed turns to non-animated navigation")
    func missingPageTurnRootDegradesCommittedTurnsToInstantNavigation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .push,
            chapterCount: 3
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigator.view.frame = container.bounds
        container.addSubview(navigator.view)
        // Default / unadapted integrations leave pageTurnRootView nil. Surface
        // prepare must fail closed on animation, but a committed turn still
        // navigates instantly instead of cancel-restoring in place.
        delegate.pageTurnRootView = nil
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-1.xhtml"))

        #expect(await navigator.goForward(options: .animated))
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)

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
            navigator.isPageTurnIdleForTesting
                && navigator.currentLocation?.href == AnyURL(string: "chapter-3.xhtml")
        })
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-3.xhtml"))
        #expect(pageTurnSurfaces(in: container).isEmpty)
    }

    @Test("loss of all mounted surfaces degrades the committed turn to instant navigation")
    func missingMountedSurfacesDegradesToInstantNavigation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .push)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        let original = try #require(navigator.currentLocation)
        delegate.resetLocationChanges()
        var removed = false
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            let surfaces = pageTurnSurfaces(in: container)
            if !removed, surfaces.count == 2 {
                removed = true
                surfaces.forEach { $0.removeFromSuperview() }
            }
        }

        #expect(await navigator.goForward(options: .animated))
        #expect(removed)
        #expect(currentPaginationView(in: navigator)?.currentIndex == 1)
        #expect(navigator.currentLocation?.href == AnyURL(string: "chapter-2.xhtml"))
        #expect(navigator.currentLocation != original)
        #expect(delegate.locationChangeCount == 1)
        #expect(pageTurnSurfaces(in: container).isEmpty)
        #expect(navigator.isPageTurnIdleForTesting)
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

    @Test("a relative surface publication cannot be negated by a later deadline")
    func relativeSurfaceDeadlineAfterPublicationStillReturnsSuccess() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .cover)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = SnapshotObservingView(frame: container.bounds)
        navigator.view.frame = root.bounds
        root.addSubview(navigator.view)
        container.addSubview(root)
        delegate.pageTurnRootView = root
        delegate.resetLocationChanges()
        navigator.setNavigationOperationTimeoutForTesting(.seconds(3))
        let postPublicationGate = Gate()
        var isWaitingAfterPublication = false
        navigator.pageTurnDisplayFrameWaiterForTesting = {
            if delegate.locationChangeCount == 1 {
                isWaitingAfterPublication = true
                await postPublicationGate.wait()
            }
        }

        let turn = Task { @MainActor in
            await navigator.goForward(options: .animated)
        }
        let result = await turn.value

        #expect(result)
        #expect(delegate.locationChangeCount == 1)
        #expect(!isWaitingAfterPublication)
        postPublicationGate.open()
        await navigator.settlePageTurn()
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

    @Test("active deadline releases an interactive page-turn waiter and all navigation diagnostics")
    func activeDeadlineReleasesInteractivePageTurnWaiter() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(pageTurnStyle: .none)
        delegate.resetLocationChanges()
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(20))

        navigator.handlePageTurnPanForTesting(
            state: .began,
            translationX: 0,
            velocityX: -700
        )

        #expect(!navigator.isNavigationQuiescentForTesting)
        #expect(await waitUntil { navigator.isNavigationQuiescentForTesting })
        #expect(
            navigator.navigationQuiescenceDiagnosticsForTesting
                == "executorActive=0,executorPending=0,executorWaiters=0,recovery=0,recoveryWaiters=0,hardAbortPending=0,hardAbortWaiters=0,snapshotIdle=1"
        )
        await navigator.settlePageTurn()
        #expect(navigator.isNavigationQuiescentForTesting)
        #expect(delegate.locationChangeCount == 0)
    }

    @Test("link resolution is bounded by the same executor deadline as navigation")
    func linkResolutionUsesNavigationExecutorDeadline() async throws {
        let (navigator, _) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 2
        )
        let link = try #require(navigator.publication.readingOrder.last)
        let gate = Gate()
        navigator.linkLocatorForTesting = { _ in
            await gate.wait()
            return nil
        }
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(20))

        let result = await navigator.go(to: link, options: .none)

        #expect(!result)
        #expect(navigator.isNavigationQuiescentForTesting)
        gate.open()
    }

    @Test("same-spread viewport movement during location calculation prevents stale publication")
    func locatorPublicationRejectsChangedViewportRevision() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let target = try #require(navigator.currentLocation)
        let paginationView = try #require(currentPaginationView(in: navigator))
        let spread = try #require(paginationView.currentView as? EPUBSpreadView)
        delegate.resetLocationChanges()
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.locatorNavigationLocationCalculationForTesting = {
            spread.scrollView.contentOffset.x += 10
            return (target, nil)
        }

        let result = await navigator.go(to: target, options: .none)

        #expect(!result)
        #expect(delegate.locationChangeCount == 0)
    }

    @Test("same-href location calculation rejects the wrong target progression")
    func locatorPublicationRejectsWrongCalculatedProgression() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let href = AnyURL(string: "chapter-1.xhtml")!
        let target = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(progression: 0.8)
        )
        let wrongCalculation = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(progression: 0.2)
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: 0.8
        )
        navigator.locatorNavigationLocationCalculationForTesting = {
            (wrongCalculation, nil)
        }
        navigator.pageTurnRestoreGoForTesting = { locator in
            navigator.pageTurnMultiColumnGeometryForTesting = (
                pageWidth: 390,
                contentWidth: 3900,
                progression: locator.locations.progression ?? 0
            )
            return true
        }
        delegate.resetLocationChanges()

        let result = await navigator.go(to: target, options: .none)

        #expect(!result)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.jumpCount == 0)
    }

    @Test("same-href location calculation rejects a different DOM target")
    func locatorPublicationRejectsWrongCalculatedDOMTarget() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1,
            chapterHTML: "<html><body><p id=\"target\">Target</p><p id=\"wrong\">Wrong</p></body></html>"
        )
        let href = AnyURL(string: "chapter-1.xhtml")!
        let target = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                progression: 0,
                otherLocations: ["cssSelector": .string("#target")]
            )
        )
        let wrongCalculation = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                progression: 0,
                otherLocations: ["cssSelector": .string("#wrong")]
            )
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.locatorNavigationDOMTargetVerifierForTesting = { _ in true }
        navigator.locatorNavigationLocationCalculationForTesting = {
            (wrongCalculation, nil)
        }
        navigator.pageTurnRestoreGoForTesting = { _ in true }
        delegate.resetLocationChanges()

        let result = await navigator.go(to: target, options: .none)

        #expect(!result)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.jumpCount == 0)
    }

    @Test("DOM range targets are reverified after asynchronous location calculation")
    func locatorPublicationReverifiesDOMRangeTarget() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1
        )
        let href = AnyURL(string: "chapter-1.xhtml")!
        let range = DOMRange(
            start: .init(cssSelector: "#target", textNodeIndex: 0, charOffset: 1)
        )
        let target = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                progression: 0,
                otherLocations: ["domRange": .object(range.jsonObject)]
            )
        )
        let calculated = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(progression: 0)
        )
        var verificationCount = 0
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.locatorNavigationDOMTargetVerifierForTesting = { _ in
            verificationCount += 1
            return true
        }
        navigator.locatorNavigationLocationCalculationForTesting = {
            (calculated, nil)
        }
        delegate.resetLocationChanges()

        let result = await navigator.go(to: target, options: .none)

        #expect(result)
        #expect(verificationCount == 2)
        #expect(delegate.locationChangeCount == 1)
        #expect(delegate.jumpCount == 1)
    }

    @Test("same-href location calculation rejects the wrong target position")
    func locatorPublicationRejectsWrongCalculatedPosition() async throws {
        let href = AnyURL(string: "chapter-1.xhtml")!
        let positions = [
            (0 ..< 10).map { index in
                Locator(
                    href: href,
                    mediaType: .xhtml,
                    locations: .init(
                        progression: Double(index) / 9,
                        position: index + 1
                    )
                )
            },
        ]
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 1,
            positionsByReadingOrder: positions
        )
        let targetProgression = Double(5) / 9
        let target = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(position: 6)
        )
        let wrongCalculation = Locator(
            href: href,
            mediaType: .xhtml,
            locations: .init(
                progression: targetProgression,
                position: 2
            )
        )
        navigator.pageTurnDisplayFrameWaiterForTesting = {}
        navigator.pageTurnGoToIndexForTesting = { _ in .applied }
        navigator.pageTurnMultiColumnGeometryForTesting = (
            pageWidth: 390,
            contentWidth: 3900,
            progression: targetProgression
        )
        navigator.locatorNavigationLocationCalculationForTesting = {
            (wrongCalculation, nil)
        }
        navigator.pageTurnRestoreGoForTesting = { locator in
            navigator.pageTurnMultiColumnGeometryForTesting = (
                pageWidth: 390,
                contentWidth: 3900,
                progression: locator.locations.progression ?? 0
            )
            return true
        }
        delegate.resetLocationChanges()

        let result = await navigator.go(to: target, options: .none)

        #expect(!result)
        #expect(delegate.locationChangeCount == 0)
        #expect(delegate.jumpCount == 0)
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

    @Test("an idle location refresh cannot overwrite a newer navigation publication")
    func staleIdleLocationRefreshCannotOverwriteNavigation() async throws {
        let (navigator, delegate) = try await makeLoadedNavigator(
            pageTurnStyle: .none,
            chapterCount: 3
        )
        let oldLocation = try #require(navigator.currentLocation)
        let refreshGate = Gate()
        var refreshStarted = false
        let refresh = Task { @MainActor in
            await navigator.performCurrentLocationRefresh {
                refreshStarted = true
                await refreshGate.wait()
                return (oldLocation, nil)
            }
        }
        #expect(await waitUntil { refreshStarted })

        #expect(await navigator.goForward(options: .none))
        let navigatedLocation = try #require(navigator.currentLocation)
        #expect(navigatedLocation.href != oldLocation.href)
        delegate.resetLocationChanges()

        refreshGate.open()
        await refresh.value

        #expect(navigator.currentLocation == navigatedLocation)
        #expect(delegate.locationChangeCount == 0)
    }

    @Test("idle location refresh returns at its deadline when calculation ignores cancellation")
    func idleLocationRefreshDeadlineDoesNotWaitForCalculation() async throws {
        let navigator = try makeNavigator()
        navigator.setNavigationOperationTimeoutForTesting(.milliseconds(20))
        let calculationGate = Gate()
        var calculationStarted = false
        var refreshFinished = false
        let refresh = Task { @MainActor in
            await navigator.performCurrentLocationRefresh {
                calculationStarted = true
                await calculationGate.wait()
                return (nil, nil)
            }
            refreshFinished = true
        }
        #expect(await waitUntil { calculationStarted })

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(refreshFinished)

        calculationGate.open()
        await refresh.value
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

    private func pageCurlViews(in view: UIView) -> [UIView] {
        view.subviews.flatMap { child in
            let descendants = pageCurlViews(in: child)
            return child.accessibilityIdentifier == "readium.page-turn.curl"
                ? [child] + descendants
                : descendants
        }
    }

    private func makeLoadedNavigator(
        pageTurnStyle: EPUBPageTurnStyle = .push,
        notificationCenter: NotificationCenter? = nil,
        accessibilityStatus: AccessibilityStatusBox? = nil,
        chapterCount: Int = 2,
        chapterHTML: String = "<html><body><p>Page</p></body></html>",
        positionsByReadingOrder: [[Locator]]? = nil
    ) async throws -> (EPUBNavigatorViewController, Delegate) {
        let readingOrder = (1 ... chapterCount).map {
            Link(href: "chapter-\($0).xhtml", mediaType: .xhtml)
        }
        let containers: [Container] = readingOrder.map { link in
            SingleResourceContainer(
                resource: DataResource(string: chapterHTML),
                at: link.url()
            )
        }
        var services = PublicationServicesBuilder()
        if let positionsByReadingOrder {
            services.setPositionsServiceFactory(
                InMemoryPositionsService.makeFactory(
                    positionsByReadingOrder: positionsByReadingOrder
                )
            )
        }
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test"),
                readingOrder: readingOrder
            ),
            container: CompositeContainer(containers),
            servicesBuilder: services
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

private extension CGImage {
    func pixelBytes(at point: CGPoint) -> [UInt8]? {
        guard
            bitsPerComponent == 8,
            bitsPerPixel == 32,
            let data = dataProvider?.data,
            point.x >= 0,
            point.y >= 0,
            point.x < CGFloat(width),
            point.y < CGFloat(height)
        else {
            return nil
        }
        let offset = Int(point.y) * bytesPerRow + Int(point.x) * 4
        let bytes = CFDataGetBytePtr(data)!
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}

private func makeBandedImage(colors: [UIColor]) -> CGImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 90))
    return renderer.image { context in
        for (index, color) in colors.enumerated() {
            color.setFill()
            context.fill(CGRect(x: 0, y: index * 30, width: 90, height: 30))
        }
    }.cgImage!
}

private func makeSideBySideImage(left: UIColor, right: UIColor) -> CGImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 30))
    return renderer.image { context in
        left.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 45, height: 30))
        right.setFill()
        context.fill(CGRect(x: 45, y: 0, width: 45, height: 30))
    }.cgImage!
}

private func makeSolidImage(_ color: UIColor) -> CGImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 90))
    return renderer.image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 90, height: 90))
    }.cgImage!
}

private func renderedCGImage(_ image: CIImage) -> CGImage? {
    CIContext(options: nil).createCGImage(image, from: image.extent)
}

private func isPredominantlyRed(_ pixel: [UInt8]) -> Bool {
    pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
}

private func isPredominantlyGreen(_ pixel: [UInt8]) -> Bool {
    pixel[0] < 60 && pixel[1] > 200 && pixel[2] < 60
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
private final class SnapshotObservingView: UIView, EPUBPageTurnSurfaceSnapshotProviding {
    var onSnapshot: (() -> Void)?
    var shouldFailSnapshots = false
    private(set) var snapshotCount = 0
    private(set) var afterScreenUpdatesValues: [Bool] = []

    func pageTurnSurfaceSnapshot(afterScreenUpdates afterUpdates: Bool) -> UIView? {
        snapshotCount += 1
        afterScreenUpdatesValues.append(afterUpdates)
        onSnapshot?()
        guard !shouldFailSnapshots else { return nil }
        if window == nil {
            return UIView(frame: bounds)
        }
        return super.snapshotView(afterScreenUpdates: afterUpdates)
    }

    override func snapshotView(afterScreenUpdates afterUpdates: Bool) -> UIView? {
        pageTurnSurfaceSnapshot(afterScreenUpdates: afterUpdates)
    }
}

/// Test double that forces color-appearance traits for RootIdentity checks.
@MainActor
private final class TraitFixedView: UIView {
    var fixedUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    var fixedAccessibilityContrast: UIAccessibilityContrast = .unspecified

    override var traitCollection: UITraitCollection {
        UITraitCollection(traitsFrom: [
            super.traitCollection,
            UITraitCollection(userInterfaceStyle: fixedUserInterfaceStyle),
            UITraitCollection(accessibilityContrast: fixedAccessibilityContrast),
        ])
    }
}

@MainActor
private func makePageTurnSurfaceController(root: UIView) -> UIViewController {
    let controller = UIViewController()
    controller.view = root
    return controller
}

@MainActor
private final class Delegate: EPUBNavigatorDelegate {
    weak var pageTurnRootView: UIView?
    var pageTurnSurfaceController: UIViewController?
    private(set) var presentationChangeCount = 0
    private(set) var locationChangeCount = 0
    private(set) var locations: [Locator] = []
    private(set) var previewEndCount = 0
    private(set) var previews: [(Locator?, NavigatorViewport?)] = []
    private(set) var errorCount = 0

    func pageTurnRootView(for navigator: EPUBNavigatorViewController) -> UIView? {
        pageTurnRootView
    }

    func pageTurnContainerViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController? {
        pageTurnSurfaceController
    }

    func pageTurnLiveSurfaceViewController(
        for navigator: EPUBNavigatorViewController
    ) -> UIViewController? {
        pageTurnSurfaceController
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationChangeCount += 1
        locations.append(locator)
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

    private(set) var jumpCount = 0
    private(set) var jumpedLocators: [Locator] = []

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        jumpCount += 1
        jumpedLocators.append(locator)
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
        locations.removeAll()
    }
}
