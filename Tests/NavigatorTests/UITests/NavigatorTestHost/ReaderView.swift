//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import ReadiumShared
import SwiftUI
import WebKit

private final class WeakObjectBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
}

/// SwiftUI wrapper for the `ReaderViewController`.
struct ReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ReaderViewControllerWrapper(navigator: viewModel.navigator)
                // State information checked in UI tests, not meant to be
                // visible.
                .background(
                    List {
                        Toggle(isOn: $viewModel.isReady) {}
                            .accessibilityIdentifier(.isNavigatorReady)
                        Toggle(isOn: $viewModel.stressTestCompleted) {}
                            .accessibilityIdentifier(.stressTestCompleted)
                        Text(viewModel.actionMarker)
                            .accessibilityIdentifier(.actionMarker)
                        Text(viewModel.currentLocationMarker)
                            .accessibilityIdentifier(.currentLocationMarker)
                        Text(viewModel.locationRevisionMarker)
                            .accessibilityIdentifier(.locationRevisionMarker)
                        Text(viewModel.firstVisibleMarker)
                            .accessibilityIdentifier(.firstVisibleMarker)
                        Text(viewModel.metricsMarker)
                            .accessibilityIdentifier(.metricsMarker)
                        Text(viewModel.viewportMetricsMarker)
                            .accessibilityIdentifier(.viewportMetricsMarker)
                        Text(viewModel.titleMarker)
                            .accessibilityIdentifier(.titleMarker)
                        Text(viewModel.modeMarker)
                            .accessibilityIdentifier(.modeMarker)
                        Text(viewModel.transitionMarker)
                            .accessibilityIdentifier(.transitionMarker)
                        Text(viewModel.selectionMarker)
                            .accessibilityIdentifier(.selectionMarker)
                        Text(viewModel.decorationMarker)
                            .accessibilityIdentifier(.decorationMarker)
                    }
                )
                .ignoresSafeArea(.all)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                        .accessibilityIdentifier(.close)
                    }

                    ToolbarItem(placement: .primaryAction) {
                        if viewModel.enablesContinuousScrollActions {
                            Menu("Test Actions") {
                                Button("Run Stress Test") {
                                    viewModel.runNavigationStressTest()
                                }
                                .accessibilityIdentifier(.runStressTest)
                                testAction("Apply Typography", .applyTypography, id: .applyTypography)
                                testAction("Shrink Typography", .shrinkTypography, id: .shrinkTypography)
                                testAction("Toggle Layout Mode", .toggleLayoutMode, id: .toggleLayoutMode)
                                testAction(
                                    "Toggle Layout Mode with Failed Neighbor",
                                    .toggleLayoutModeWithFailedNeighbor,
                                    id: .toggleLayoutModeWithFailedNeighbor
                                )
                                testAction(
                                    "Rapidly Toggle Layout Mode",
                                    .rapidlyToggleLayoutMode,
                                    id: .rapidlyToggleLayoutMode
                                )
                                testAction(
                                    "Toggle Layout Mode with Failed Current Resource",
                                    .toggleLayoutModeWithFailedCurrent,
                                    id: .toggleLayoutModeWithFailedCurrent
                                )
                                Menu("Navigation Actions") {
                                    testAction("Jump to Missing Resource", .jumpMissingResource, id: .jumpMissingResource)
                                    testAction("Jump First Resource End", .jumpFirstResourceEnd, id: .jumpFirstResourceEnd)
                                    testAction("Jump Fragment", .jumpFragment, id: .jumpFragment)
                                    testAction("Jump Text", .jumpText, id: .jumpText)
                                    testAction("Jump Table of Contents", .jumpTableOfContents, id: .jumpTableOfContents)
                                    testAction("Jump 10 Percent", .jumpProgression10, id: .jumpProgression10)
                                    testAction("Jump 80 Percent", .jumpProgression80, id: .jumpProgression80)
                                    testAction("Jump Reflow Marker", .jumpReflowMarker, id: .jumpReflowMarker)
                                }
                                .accessibilityIdentifier(.navigationActions)
                                Menu("Capture Actions") {
                                    testAction("Capture Current Location", .captureCurrentLocation, id: .captureCurrentLocation)
                                    testAction("Capture First Visible", .captureFirstVisible, id: .captureFirstVisible)
                                    testAction("Capture Metrics", .captureMetrics, id: .captureMetrics)
                                    testAction("Capture Viewport Metrics", .captureViewportMetrics, id: .captureViewportMetrics)
                                    testAction("Capture Title", .captureTitle, id: .captureTitle)
                                    testAction("Capture Selection", .captureSelection, id: .captureSelection)
                                }
                                .accessibilityIdentifier(.captureActions)
                            }
                            .accessibilityIdentifier(.testActions)
                        } else {
                            Button("Run Stress Test") {
                                viewModel.runNavigationStressTest()
                            }
                            .accessibilityIdentifier(.runStressTest)
                        }
                    }
                }
        }
    }

    private func testAction(
        _ title: String,
        _ action: ReaderTestAction,
        id: AccessibilityID
    ) -> some View {
        Button(title) {
            viewModel.runTestAction(action)
        }
        .accessibilityIdentifier(id)
    }
}

enum ReaderTestAction: String {
    case applyTypography
    case shrinkTypography
    case toggleLayoutMode
    case toggleLayoutModeWithFailedNeighbor
    case rapidlyToggleLayoutMode
    case toggleLayoutModeWithFailedCurrent
    case jumpMissingResource
    case jumpFirstResourceEnd
    case jumpFragment
    case jumpText
    case jumpTableOfContents
    case jumpProgression10
    case jumpProgression80
    case jumpReflowMarker
    case captureCurrentLocation
    case captureFirstVisible
    case captureMetrics
    case captureViewportMetrics
    case captureTitle
    case captureSelection
}

@MainActor final class ReaderViewModel: ObservableObject, Identifiable {
    nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    let navigator: VisualNavigator & UIViewController
    let enablesContinuousScrollActions: Bool

    @Published var isReady: Bool = false
    @Published var stressTestCompleted: Bool = false
    @Published var actionMarker = "idle"
    @Published var currentLocationMarker = "none"
    @Published var locationRevisionMarker = "none"
    @Published var firstVisibleMarker = "none"
    @Published var metricsMarker = "none"
    @Published var viewportMetricsMarker = "none"
    @Published var titleMarker = "none"
    @Published var modeMarker = "paged"
    @Published var transitionMarker = "none"
    @Published var selectionMarker = "none"
    @Published var decorationMarker = "none"

    private var epubPreferences: EPUBPreferences
    private var directionalNavigationAdapter: DirectionalNavigationAdapter?
    private var actionTask: Task<Void, Never>?
    private var actionGeneration = 0
    private var locationRevision = 0
    private var latestLocator: Locator?
    private var locationWaiter: LocationWaiter?
    private let resourceFailureController: ResourceFailureController?
    private var resourceFailureRevision = 0
    private var lastFailedResourceHREF: RelativeURL?

    init(
        navigator: VisualNavigator & UIViewController,
        enablesContinuousScrollActions: Bool = false,
        epubPreferences: EPUBPreferences = .empty,
        resourceFailureController: ResourceFailureController? = nil
    ) {
        self.navigator = navigator
        self.enablesContinuousScrollActions = enablesContinuousScrollActions
        self.epubPreferences = epubPreferences
        self.resourceFailureController = resourceFailureController
        modeMarker = epubPreferences.scroll == true ? "continuous" : "paged"

        if let epubNavigator = navigator as? EPUBNavigatorViewController {
            epubNavigator.delegate = self
        } else if let pdfNavigator = navigator as? PDFNavigatorViewController {
            pdfNavigator.delegate = self
        }

        directionalNavigationAdapter = DirectionalNavigationAdapter()
        directionalNavigationAdapter?.bind(to: navigator)

        if
            enablesContinuousScrollActions,
            let navigator = navigator as? EPUBNavigatorViewController
        {
            installInteractionEvidence(in: navigator)
        }
    }

    deinit {
        actionTask?.cancel()
    }

    func runNavigationStressTest() {
        actionTask?.cancel()
        stressTestCompleted = false
        actionTask = Task { [weak self] in
            guard let self else { return }

            if enablesContinuousScrollActions {
                await runContinuousNavigationStressTest()
                return
            }

            let publication = navigator.publication
            let readingOrder = publication.readingOrder
            guard let positionsByReadingOrder = await publication.positionsByReadingOrder().getOrNil() else { return }

            for _ in 0 ..< 100 {
                let positions = positionsByReadingOrder[Int.random(in: 0 ..< readingOrder.count)]
                let locator = positions[Int.random(in: 0 ..< positions.count)]
                await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
                let sleepNanos = UInt64.random(in: 0 ... 50) * 1_000_000
                try? await Task.sleep(nanoseconds: sleepNanos)
            }

            stressTestCompleted = true
        }
    }

    private func runContinuousNavigationStressTest() async {
        let seed: UInt64 = 12_648_430
        let operationCount = 100
        actionGeneration += 1
        let generation = actionGeneration
        actionMarker = "running:continuousStress:\(generation)|seed=\(seed)"

        guard let navigator = navigator as? EPUBNavigatorViewController else {
            failContinuousStress(generation: generation, reason: "not-epub")
            return
        }

        let publication = navigator.publication
        let readingOrder = publication.readingOrder
        guard readingOrder.count == 50 else {
            failContinuousStress(generation: generation, reason: "resource-count-\(readingOrder.count)")
            return
        }
        guard let tableOfContents = await publication.tableOfContents().getOrNil(), !tableOfContents.isEmpty else {
            failContinuousStress(generation: generation, reason: "missing-toc")
            return
        }

        var random = SeededRandomNumberGenerator(seed: seed)
        var counts = [Int](repeating: 0, count: 5)

        for operation in 0 ..< operationCount {
            guard !Task.isCancelled else { return }

            let kind = random.nextInt(upperBound: counts.count)
            counts[kind] += 1

            if kind == 4 {
                guard let direction = await waitForStressDragDirection(in: navigator) else {
                    failContinuousStress(generation: generation, reason: "missing-drag-range")
                    return
                }
                let revision = locationRevision
                actionMarker = "drag:continuousStress:\(generation):\(operation)|\(direction)"
                _ = await waitForLocation(after: revision) { _ in true }
                continue
            }

            let locator: Locator
            switch kind {
            case 0:
                var index = random.nextInt(upperBound: tableOfContents.count)
                if latestLocator?.href.isEquivalentTo(tableOfContents[index].url()) == true {
                    index = (index + 1) % tableOfContents.count
                }
                guard let target = await publication.locate(tableOfContents[index]) else {
                    failContinuousStress(generation: generation, reason: "toc-\(operation)")
                    return
                }
                locator = target

            case 1:
                let index = randomResourceIndex(in: readingOrder, using: &random)
                let link = readingOrder[index]
                locator = Locator(
                    href: link.url(),
                    mediaType: link.mediaType ?? .xhtml,
                    locations: .init(fragments: ["chapter-\(index + 1)-start"])
                )

            case 2:
                let index = randomResourceIndex(in: readingOrder, using: &random)
                let link = readingOrder[index]
                let chapter = String(format: "%02d", locale: Locale(identifier: "en_US_POSIX"), index + 1)
                locator = Locator(
                    href: link.url(),
                    mediaType: link.mediaType ?? .xhtml,
                    locations: .init(),
                    text: .init(highlight: "CHAPTER-\(chapter)-START")
                )

            default:
                let index = randomResourceIndex(in: readingOrder, using: &random)
                let link = readingOrder[index]
                let progression = Double(random.nextInt(upperBound: 81) + 10) / 100
                locator = Locator(
                    href: link.url(),
                    mediaType: link.mediaType ?? .xhtml,
                    locations: .init(progression: progression)
                )
            }

            actionMarker = "running:continuousStress:\(generation):\(operation)"
            guard await navigate(to: locator, predicate: { _ in true }) != nil else {
                failContinuousStress(generation: generation, reason: "go-\(operation)")
                return
            }
        }

        let restoreLink = readingOrder[1]
        let restoreLocator = Locator(
            href: restoreLink.url(),
            mediaType: restoreLink.mediaType ?? .xhtml,
            locations: .init(progression: 0.5)
        )
        guard await navigate(to: restoreLocator, predicate: { $0.href.isEquivalentTo(restoreLink.url()) }) != nil else {
            failContinuousStress(generation: generation, reason: "restore")
            return
        }

        stressTestCompleted = true
        actionMarker = "done:continuousStress:\(generation)|seed=\(seed)|operations=\(operationCount)|toc=\(counts[0])|fragment=\(counts[1])|text=\(counts[2])|progression=\(counts[3])|drag=\(counts[4])"
    }

    private func randomResourceIndex(
        in readingOrder: [ReadiumShared.Link],
        using random: inout SeededRandomNumberGenerator
    ) -> Int {
        var index = random.nextInt(upperBound: readingOrder.count)
        if latestLocator?.href.isEquivalentTo(readingOrder[index].url()) == true {
            index = (index + 1) % readingOrder.count
        }
        return index
    }

    private func stressDragDirection(in navigator: EPUBNavigatorViewController) -> String? {
        navigator.view.layoutIfNeeded()
        guard let scrollView = outerScrollView(in: navigator.view) else { return nil }

        let inset = scrollView.adjustedContentInset
        let minimumOffset = -inset.top
        let maximumOffset = max(
            minimumOffset,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        guard maximumOffset - minimumOffset > 1 else { return nil }

        let offset = min(max(scrollView.contentOffset.y, minimumOffset), maximumOffset)
        return maximumOffset - offset >= offset - minimumOffset ? "up" : "down"
    }

    private func waitForStressDragDirection(
        in navigator: EPUBNavigatorViewController
    ) async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if let direction = stressDragDirection(in: navigator) {
                return direction
            }
            await Task.yield()
        }
        return nil
    }

    private func failContinuousStress(generation: Int, reason: String) {
        actionMarker = "failed:continuousStress:\(generation):\(reason)"
    }

    func runTestAction(_ action: ReaderTestAction) {
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            await self?.perform(action)
        }
    }

    private func perform(_ action: ReaderTestAction) async {
        actionGeneration += 1
        let generation = actionGeneration
        actionMarker = "running:\(action.rawValue):\(generation)"

        guard let navigator = navigator as? EPUBNavigatorViewController else {
            fail(action, generation: generation, reason: "not-epub")
            return
        }

        switch action {
        case .applyTypography:
            let previousHeight = await documentHeight(in: navigator)
            let revision = locationRevision
            epubPreferences.fontSize = 1.25
            epubPreferences.lineHeight = 1.5
            navigator.submitPreferences(epubPreferences)

            while !Task.isCancelled {
                await Task.yield()
                if let height = await documentHeight(in: navigator), height != previousHeight {
                    break
                }
            }
            if locationRevision == revision {
                _ = await waitForLocation(after: revision) { _ in true }
            }
            complete(action, generation: generation)

        case .shrinkTypography:
            let previousHeight = await documentHeight(in: navigator)
            let revision = locationRevision
            epubPreferences.fontSize = 0.75
            epubPreferences.lineHeight = 1
            navigator.submitPreferences(epubPreferences)

            while !Task.isCancelled {
                await Task.yield()
                if let height = await documentHeight(in: navigator), height != previousHeight {
                    break
                }
            }
            if locationRevision == revision {
                _ = await waitForLocation(after: revision) { _ in true }
            }
            complete(action, generation: generation)

        case .toggleLayoutMode:
            let titleBeforeTransition = await documentTitle(in: navigator) ?? "missing"
            let token = UUID().uuidString
            _ = await navigator.evaluateJavaScript("window.__readiumUITestModeToken = '\(token)'")
            epubPreferences.scroll = !(epubPreferences.scroll ?? false)
            navigator.submitPreferences(epubPreferences)

            // Exercise the navigation path synchronously, before the queued
            // pagination invalidation can complete. The navigator must reject
            // this wrong-axis input while its replacement is loading.
            let movedDuringTransition = await navigator.goForward(
                options: .init(animated: false)
            )

            while !Task.isCancelled {
                await Task.yield()
                let result = await navigator.evaluateJavaScript("window.__readiumUITestModeToken")
                if case let .success(value) = result, (value as? String) != token {
                    break
                }
            }
            let titleAfterTransition = await documentTitle(in: navigator) ?? "missing"
            transitionMarker = "generation=\(generation)|moved=\(movedDuringTransition)|before=\(titleBeforeTransition)|after=\(titleAfterTransition)"
            modeMarker = epubPreferences.scroll == true ? "continuous" : "paged"
            complete(action, generation: generation)

        case .toggleLayoutModeWithFailedNeighbor:
            guard
                let originalLink = readingOrderLink(at: 0),
                let targetLink = readingOrderLink(at: 2),
                let lifetime = paginationLifetime(in: navigator)
            else {
                fail(action, generation: generation, reason: "missing-transition-state")
                return
            }

            let token = UUID().uuidString
            _ = await navigator.evaluateJavaScript("window.__readiumUITestModeToken = '\(token)'")
            epubPreferences.scroll = false
            navigator.submitPreferences(epubPreferences)

            await waitUntilReleased(lifetime)
            guard !Task.isCancelled else { return }

            let targetLocator = Locator(
                href: targetLink.url(),
                mediaType: targetLink.mediaType ?? .xhtml
            )
            let targetLocation = await navigate(to: targetLocator) {
                $0.href.isEquivalentTo(targetLink.url())
            }
            let targetTitle = await documentTitle(in: navigator) ?? "missing"

            let originalLocator = Locator(
                href: originalLink.url(),
                mediaType: originalLink.mediaType ?? .xhtml
            )
            let originalLocation = await navigate(to: originalLocator) {
                $0.href.isEquivalentTo(originalLink.url())
            }
            let originalTitle = await documentTitle(in: navigator) ?? "missing"
            let tokenResult = await navigator.evaluateJavaScript("window.__readiumUITestModeToken")
            let tokenPreserved: Bool = if case let .success(value) = tokenResult {
                value as? String == token
            } else {
                false
            }

            transitionMarker = "generation=\(generation)|scroll=\(navigator.settings.scroll)|oldPaginationReleased=\(lifetime.pagination.value == nil)|oldWebViewsReleased=\(lifetime.webViews.allSatisfy { $0.value == nil })|tokenPreserved=\(tokenPreserved)|targetReached=\(targetLocation != nil)|target=\(targetTitle)|originalReached=\(originalLocation != nil)|original=\(originalTitle)"
            modeMarker = navigator.settings.scroll ? "continuous" : "paged"
            complete(action, generation: generation)

        case .rapidlyToggleLayoutMode:
            guard
                let originalLink = readingOrderLink(at: 0),
                let targetLink = readingOrderLink(at: 2),
                let lifetime = paginationLifetime(in: navigator)
            else {
                fail(action, generation: generation, reason: "missing-transition-state")
                return
            }

            for isScrollEnabled in [false, true, false] {
                epubPreferences.scroll = isScrollEnabled
                navigator.submitPreferences(epubPreferences)
                await nextMainRunLoop()
            }

            await waitUntilReleased(lifetime)
            guard !Task.isCancelled else { return }

            let targetLocator = Locator(
                href: targetLink.url(),
                mediaType: targetLink.mediaType ?? .xhtml
            )
            let targetLocation = await navigate(to: targetLocator) {
                $0.href.isEquivalentTo(targetLink.url())
            }
            let targetTitle = await documentTitle(in: navigator) ?? "missing"
            let originalLocator = Locator(
                href: originalLink.url(),
                mediaType: originalLink.mediaType ?? .xhtml
            )
            let originalLocation = await navigate(to: originalLocator) {
                $0.href.isEquivalentTo(originalLink.url())
            }
            let originalTitle = await documentTitle(in: navigator) ?? "missing"

            transitionMarker = "generation=\(generation)|scroll=\(navigator.settings.scroll)|oldPaginationReleased=\(lifetime.pagination.value == nil)|oldWebViewsReleased=\(lifetime.webViews.allSatisfy { $0.value == nil })|paginationCount=\(paginationViewCount(in: navigator))|targetReached=\(targetLocation != nil)|target=\(targetTitle)|originalReached=\(originalLocation != nil)|original=\(originalTitle)"
            modeMarker = navigator.settings.scroll ? "continuous" : "paged"
            complete(action, generation: generation)

        case .toggleLayoutModeWithFailedCurrent:
            guard
                let resourceFailureController,
                let currentLink = readingOrderLink(at: 0)
            else {
                fail(action, generation: generation, reason: "missing-failure-controller")
                return
            }

            let endLocator = Locator(
                href: currentLink.url(),
                mediaType: currentLink.mediaType ?? .xhtml,
                locations: .init(progression: 1)
            )
            guard await navigate(to: endLocator, predicate: {
                $0.href.isEquivalentTo(currentLink.url())
            }) != nil else {
                fail(action, generation: generation, reason: "positioning-failed")
                return
            }

            let titleBeforeTransition = await documentTitle(in: navigator) ?? "missing"
            let token = UUID().uuidString
            _ = await navigator.evaluateJavaScript("window.__readiumUITestModeToken = '\(token)'")
            resourceFailureController.failResource(at: currentLink.url())
            let previousFailureRevision = resourceFailureRevision

            epubPreferences.scroll = true
            navigator.submitPreferences(epubPreferences)
            let movedDuringTransition = await navigator.goForward(
                options: .init(animated: false)
            )

            while !Task.isCancelled, resourceFailureRevision == previousFailureRevision {
                await Task.yield()
            }
            while !Task.isCancelled, navigator.settings.scroll {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }

            epubPreferences.scroll = navigator.settings.scroll
            let tokenResult = await navigator.evaluateJavaScript("window.__readiumUITestModeToken")
            let restoredToken: String?
            switch tokenResult {
            case let .success(value):
                restoredToken = value as? String
            case .failure:
                restoredToken = nil
            }
            let titleAfterTransition = await documentTitle(in: navigator) ?? "missing"
            transitionMarker = "generation=\(generation)|moved=\(movedDuringTransition)|failure=\(lastFailedResourceHREF?.string ?? "none")|tokenRestored=\(restoredToken == token)|before=\(titleBeforeTransition)|after=\(titleAfterTransition)"
            modeMarker = navigator.settings.scroll ? "continuous" : "paged"
            complete(action, generation: generation)

        case .jumpMissingResource:
            guard let link = readingOrderLink(at: 1) else {
                fail(action, generation: generation, reason: "missing-link")
                return
            }
            let titleBeforeNavigation = await documentTitle(in: navigator) ?? "missing"
            let previousFailureRevision = resourceFailureRevision
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml
            )
            let result = await navigator.go(
                to: locator,
                options: .init(animated: false)
            )
            guard resourceFailureRevision > previousFailureRevision else {
                fail(action, generation: generation, reason: "missing-failure-callback")
                return
            }
            let titleAfterNavigation = await documentTitle(in: navigator) ?? "missing"
            transitionMarker = "generation=\(generation)|result=\(result)|failure=\(lastFailedResourceHREF?.string ?? "none")|before=\(titleBeforeNavigation)|after=\(titleAfterNavigation)"
            complete(action, generation: generation)

        case .jumpFirstResourceEnd:
            guard let link = readingOrderLink(at: 0) else {
                fail(action, generation: generation, reason: "missing-link")
                return
            }
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: .init(progression: 1)
            )
            await jump(to: locator, action: action, generation: generation) { locator in
                locator.href.isEquivalentTo(link.url())
            }

        case .jumpFragment:
            guard let link = readingOrderLink(at: 1) else {
                fail(action, generation: generation, reason: "missing-link")
                return
            }
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: .init(fragments: ["fragment-target"])
            )
            await jump(to: locator, action: action, generation: generation) { locator in
                locator.href.isEquivalentTo(link.url())
            }

        case .jumpText:
            guard let link = readingOrderLink(at: 1) else {
                fail(action, generation: generation, reason: "missing-link")
                return
            }
            var locations = Locator.Locations()
            locations.cssSelector = "#text-target"
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: locations,
                text: .init(highlight: "UNIQUE TEXT QUOTE TARGET")
            )
            await jump(to: locator, action: action, generation: generation) { locator in
                locator.href.isEquivalentTo(link.url())
                    && (locator.locations.progression ?? 0) > 0.35
            }

        case .jumpTableOfContents:
            guard
                let tableOfContents = await navigator.publication.tableOfContents().getOrNil(),
                let link = tableOfContents.last,
                let target = await navigator.publication.locate(link)
            else {
                fail(action, generation: generation, reason: "missing-toc")
                return
            }
            await jump(to: target, action: action, generation: generation) { locator in
                locator.href.isEquivalentTo(target.href)
            }

        case .jumpProgression10:
            await jumpToProgression(0.1, action: action, generation: generation)

        case .jumpProgression80:
            await jumpToProgression(0.8, action: action, generation: generation)

        case .jumpReflowMarker:
            guard let link = readingOrderLink(at: 2) else {
                fail(action, generation: generation, reason: "missing-link")
                return
            }
            var locations = Locator.Locations()
            locations.cssSelector = "#reflow-marker"
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: locations
            )
            await jump(to: locator, action: action, generation: generation) { locator in
                locator.href.isEquivalentTo(link.url())
            }

        case .captureCurrentLocation:
            guard let locator = navigator.currentLocation else {
                fail(action, generation: generation, reason: "missing-current")
                return
            }
            currentLocationMarker = describe(locator)
            complete(action, generation: generation)

        case .captureFirstVisible:
            guard let locator = await navigator.firstVisibleElementLocator() else {
                fail(action, generation: generation, reason: "missing-first-visible")
                return
            }
            firstVisibleMarker = describe(locator)
            complete(action, generation: generation)

        case .captureMetrics:
            let result = await navigator.evaluateJavaScript("""
                (() => {
                    const element = document.getElementById('reflow-marker');
                    if (!element) return null;
                    const rect = element.getBoundingClientRect();
                    return { y: rect.top + window.scrollY, height: rect.height };
                })()
                """)
            guard
                case let .success(value) = result,
                let metrics = value as? [String: Any],
                let y = (metrics["y"] as? NSNumber)?.doubleValue,
                let height = (metrics["height"] as? NSNumber)?.doubleValue
            else {
                fail(action, generation: generation, reason: "missing-metrics")
                return
            }
            metricsMarker = String(
                format: "y=%.3f|h=%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                y,
                height
            )
            complete(action, generation: generation)

        case .captureViewportMetrics:
            navigator.view.layoutIfNeeded()
            guard
                let scrollView = outerScrollView(in: navigator.view),
                let documentHeight = await documentHeight(in: navigator),
                let spreadHeight = currentSpreadFrameHeight(in: scrollView)
            else {
                fail(action, generation: generation, reason: "missing-outer-scroll-view")
                return
            }
            let inset = scrollView.adjustedContentInset
            viewportMetricsMarker = String(
                format: "offsetY=%.3f|viewportHeight=%.3f|documentHeight=%.3f|spreadHeight=%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                scrollView.contentOffset.y,
                max(0, scrollView.bounds.height - inset.top - inset.bottom),
                documentHeight,
                spreadHeight
            )
            complete(action, generation: generation)

        case .captureTitle:
            guard let title = await documentTitle(in: navigator) else {
                fail(action, generation: generation, reason: "missing-title")
                return
            }
            titleMarker = title
            complete(action, generation: generation)

        case .captureSelection:
            while !Task.isCancelled, navigator.currentSelection == nil {
                await Task.yield()
            }
            guard
                let selection = navigator.currentSelection,
                let frame = selection.frame
            else {
                fail(action, generation: generation, reason: "missing-selection")
                return
            }
            selectionMarker = String(
                format: "%@|x=%.3f|y=%.3f|w=%.3f|h=%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                selection.locator.href.string,
                frame.minX,
                frame.minY,
                frame.width,
                frame.height
            )
            complete(action, generation: generation)
        }
    }

    private func installInteractionEvidence(in navigator: EPUBNavigatorViewController) {
        guard let link = readingOrderLink(at: 1) else { return }

        var locations = Locator.Locations()
        locations.cssSelector = "#chapter-2-start"
        let locator = Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .xhtml,
            locations: locations
        )
        let decoration = Decoration(
            id: Self.interactionDecorationID,
            locator: locator,
            style: .highlight(isActive: true)
        )

        navigator.observeDecorationInteractions(inGroup: Self.interactionDecorationGroup) { [weak self] event in
            guard
                let self,
                let rect = event.rect,
                let point = event.point
            else {
                return
            }
            decorationMarker = String(
                format: "%@|x=%.3f|y=%.3f|w=%.3f|h=%.3f|px=%.3f|py=%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                event.decoration.locator.href.string,
                rect.minX,
                rect.minY,
                rect.width,
                rect.height,
                point.x,
                point.y
            )
        }
        navigator.apply(
            decorations: [decoration],
            in: Self.interactionDecorationGroup
        )
    }

    private static let interactionDecorationID = "continuous-scroll-second-resource"
    private static let interactionDecorationGroup = "continuous-scroll-interactions"

    private func jumpToProgression(
        _ progression: Double,
        action: ReaderTestAction,
        generation: Int
    ) async {
        guard let link = readingOrderLink(at: 2) else {
            fail(action, generation: generation, reason: "missing-link")
            return
        }
        let locator = Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .xhtml,
            locations: .init(progression: progression)
        )
        await jump(to: locator, action: action, generation: generation) { locator in
            guard locator.href.isEquivalentTo(link.url()), let actual = locator.locations.progression else {
                return false
            }
            return progression < 0.5 ? actual < 0.25 : actual > 0.65
        }
    }

    private func jump(
        to locator: Locator,
        action: ReaderTestAction,
        generation: Int,
        predicate: @escaping (Locator) -> Bool
    ) async {
        guard let current = await navigate(to: locator, predicate: predicate) else {
            fail(action, generation: generation, reason: "go-failed")
            return
        }
        currentLocationMarker = describe(current)
        complete(action, generation: generation)
    }

    private func navigate(
        to locator: Locator,
        predicate: @escaping (Locator) -> Bool
    ) async -> Locator? {
        let revision = locationRevision
        guard await navigator.go(to: locator, options: .init(animated: false)) else {
            return nil
        }
        return await waitForLocation(after: revision, predicate: predicate)
    }

    private func waitForLocation(
        after revision: Int,
        predicate: @escaping (Locator) -> Bool
    ) async -> Locator {
        if
            locationRevision > revision,
            let latestLocator,
            predicate(latestLocator)
        {
            return latestLocator
        }

        return await withCheckedContinuation { continuation in
            locationWaiter = LocationWaiter(
                revision: revision,
                predicate: predicate,
                continuation: continuation
            )
        }
    }

    private func readingOrderLink(at index: Int) -> ReadiumShared.Link? {
        let readingOrder = navigator.publication.readingOrder
        return readingOrder.indices.contains(index) ? readingOrder[index] : nil
    }

    private func documentHeight(in navigator: EPUBNavigatorViewController) async -> Double? {
        let result = await navigator.evaluateJavaScript("readium.documentHeight()")
        guard case let .success(value) = result else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private func documentTitle(in navigator: EPUBNavigatorViewController) async -> String? {
        let result = await navigator.evaluateJavaScript("document.title")
        guard case let .success(value) = result else { return nil }
        return value as? String
    }

    private func outerScrollView(in rootView: UIView) -> UIScrollView? {
        var queue = rootView.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func currentSpreadFrameHeight(in scrollView: UIScrollView) -> CGFloat? {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = max(0, scrollView.bounds.height - inset.top - inset.bottom)
        let centerY = scrollView.contentOffset.y + inset.top + viewportHeight / 2
        return scrollView.subviews.first { view in
            !view.isHidden
                && view.frame.width >= scrollView.bounds.width * 0.9
                && centerY >= view.frame.minY
                && centerY < view.frame.maxY
        }?.frame.height
    }

    private func paginationLifetime(in navigator: EPUBNavigatorViewController) -> PaginationLifetime? {
        guard
            let scrollView = outerScrollView(in: navigator.view),
            let paginationView = scrollView.superview
        else {
            return nil
        }
        return PaginationLifetime(
            pagination: WeakObjectBox(paginationView),
            webViews: allWebViews(in: paginationView).map(WeakObjectBox.init)
        )
    }

    private func allWebViews(in rootView: UIView) -> [WKWebView] {
        var result: [WKWebView] = []
        var queue = rootView.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let webView = view as? WKWebView {
                result.append(webView)
            }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    private func waitUntilReleased(_ lifetime: PaginationLifetime) async {
        while
            !Task.isCancelled,
            lifetime.pagination.value != nil
                || lifetime.webViews.contains(where: { $0.value != nil })
        {
            await Task.yield()
        }
    }

    private func paginationViewCount(in navigator: EPUBNavigatorViewController) -> Int {
        navigator.view.subviews.filter { view in
            view.subviews.contains { $0 is UIScrollView }
        }.count
    }

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func describe(_ locator: Locator) -> String {
        let progression = locator.locations.progression ?? -1
        return String(
            format: "%@|p=%.5f|css=%@",
            locale: Locale(identifier: "en_US_POSIX"),
            locator.href.string,
            progression,
            locator.locations.cssSelector ?? "none"
        )
    }

    private func complete(_ action: ReaderTestAction, generation: Int) {
        actionMarker = "done:\(action.rawValue):\(generation)"
    }

    private func fail(_ action: ReaderTestAction, generation: Int, reason: String) {
        actionMarker = "failed:\(action.rawValue):\(generation):\(reason)"
    }

    private struct LocationWaiter {
        let revision: Int
        let predicate: (Locator) -> Bool
        let continuation: CheckedContinuation<Locator, Never>
    }

    private struct PaginationLifetime {
        let pagination: WeakObjectBox<UIView>
        let webViews: [WeakObjectBox<WKWebView>]
    }

    private struct SeededRandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func nextInt(upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state % UInt64(upperBound))
        }
    }
}

// MARK: - NavigatorDelegate

extension ReaderViewModel: NavigatorDelegate {
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

    func navigator(
        _ navigator: Navigator,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        resourceFailureRevision += 1
        lastFailedResourceHREF = href
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationRevision += 1
        latestLocator = locator
        currentLocationMarker = describe(locator)
        locationRevisionMarker = "r=\(locationRevision)|\(describe(locator))"
        if enablesContinuousScrollActions {
            Container.shared.continuousScrollLocation = locator
        }

        if
            let waiter = locationWaiter,
            locationRevision > waiter.revision,
            waiter.predicate(locator)
        {
            locationWaiter = nil
            waiter.continuation.resume(returning: locator)
        }

        if !isReady {
            isReady = true
        }
    }
}

extension ReaderViewModel: EPUBNavigatorDelegate {
    func navigator(
        _ navigator: EPUBNavigatorViewController,
        setupUserScripts userContentController: WKUserContentController
    ) {
        guard enablesContinuousScrollActions else { return }

        let source = """
            document.addEventListener('click', event => {
                const target = event.target instanceof Element
                    ? event.target.closest('#chapter-2-start')
                    : null;
                if (!target) return;

                const range = document.createRange();
                range.selectNodeContents(target);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);

                const rect = target.getBoundingClientRect();
                window.webkit.messageHandlers.decorationActivated.postMessage({
                    id: '\(Self.interactionDecorationID)',
                    group: '\(Self.interactionDecorationGroup)',
                    rect: {
                        left: rect.left,
                        top: rect.top,
                        width: rect.width,
                        height: rect.height
                    },
                    click: {
                        x: event.clientX,
                        y: event.clientY,
                        targetElement: target.outerHTML,
                        defaultPrevented: event.defaultPrevented
                    }
                });
            });
            """
        userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
    }

    func navigator(
        _ navigator: SelectableNavigator,
        shouldShowMenuForSelection selection: Selection
    ) -> Bool {
        !enablesContinuousScrollActions
    }
}
extension ReaderViewModel: PDFNavigatorDelegate {}
