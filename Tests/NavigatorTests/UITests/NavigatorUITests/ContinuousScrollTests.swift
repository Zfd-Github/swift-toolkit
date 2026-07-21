//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

final class ContinuousScrollTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testMissingResourceNavigationFailsAndPreservesCurrentPage() {
        let reader = app.open(.continuousScrollFailedNeighborEPUB, waitUntilReady: true)

        reader.runAction(
            .jumpMissingResource,
            completionPrefix: "jumpMissingResource",
            timeout: 30
        )

        let transition = reader.marker(.transitionMarker)
        XCTAssertTrue(transition.contains("result=false"), transition)
        XCTAssertTrue(transition.contains("failure=missing-neighbor.xhtml"), transition)
        XCTAssertTrue(transition.contains("before=Chapter 01"), transition)
        XCTAssertTrue(transition.contains("after=Chapter 01"), transition)

        reader.close(assertMemoryDeallocated: true)
    }

    func testFailedCurrentResourceRollsBackLayoutTransition() {
        let reader = app.open(
            .continuousScrollFailedCurrentTransitionEPUB,
            waitUntilReady: true
        )
        reader.runAction(
            .toggleLayoutModeWithFailedCurrent,
            completionPrefix: "toggleLayoutModeWithFailedCurrent",
            timeout: 30
        )

        let transition = reader.marker(.transitionMarker)
        XCTAssertTrue(transition.contains("moved=false"), transition)
        XCTAssertTrue(transition.contains("failure=OEBPS/chapter-01.xhtml"), transition)
        XCTAssertTrue(transition.contains("tokenRestored=true"), transition)
        XCTAssertTrue(transition.contains("before=Chapter 01"), transition)
        XCTAssertTrue(transition.contains("after=Chapter 01"), transition)
        XCTAssertEqual(reader.marker(.modeMarker), "paged")

        let revisionBeforePageTurn = reader.marker(.locationRevisionMarker)
        reader.viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let locationRevisionMarker = app.staticTexts[.locationRevisionMarker].firstMatch
        XCTAssertTrue(locationRevisionMarker.waitUntil(timeout: 30) {
            locationRevisionMarker.label != revisionBeforePageTurn
                && locationRevisionMarker.label.contains("chapter-02.xhtml")
        })
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), "Chapter 02")

        reader.close(assertMemoryDeallocated: true)
    }

    func testRapidLayoutTogglesUseLastPreferenceAndReleaseOldViews() {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)

        reader.runAction(
            .rapidlyToggleLayoutMode,
            completionPrefix: "rapidlyToggleLayoutMode",
            timeout: 90
        )

        let transition = reader.marker(.transitionMarker)
        XCTAssertTrue(transition.contains("scroll=false"), transition)
        XCTAssertTrue(transition.contains("oldPaginationReleased=true"), transition)
        XCTAssertTrue(transition.contains("oldWebViewsReleased=true"), transition)
        XCTAssertTrue(transition.contains("paginationCount=1"), transition)
        XCTAssertTrue(transition.contains("targetReached=true"), transition)
        XCTAssertTrue(transition.contains("target=Chapter 03"), transition)
        XCTAssertTrue(transition.contains("originalReached=true"), transition)
        XCTAssertTrue(transition.contains("original=Chapter 01"), transition)
        XCTAssertEqual(reader.marker(.modeMarker), "paged")

        reader.close(assertMemoryDeallocated: true)
    }

    func testContinuousResourceBoundaryIncludesFinalLine() throws {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)

        reader.runAction(.jumpFirstResourceEnd, completionPrefix: "jumpFirstResourceEnd")
        reader.runAction(.captureMetrics, completionPrefix: "captureMetrics")
        let metrics = metricsValues(from: reader.marker(.metricsMarker))

        XCTAssertGreaterThan(
            try XCTUnwrap(metrics["bottom"]),
            try XCTUnwrap(metrics["bodyHeight"]),
            "Fixture must preserve the collapsed-margin boundary case: \(metrics)"
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(metrics["bottom"]),
            try XCTUnwrap(metrics["documentHeight"]),
            "Final line must fit inside the measured resource height: \(metrics)"
        )

        reader.close(assertMemoryDeallocated: true)
    }

    func testContinuousViewportAndModeInputs() throws {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        let viewport = reader.viewport
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))

        viewport.swipeUp()

        let chapterEnd = app.staticTexts["CHAPTER-01-END"].firstMatch
        let chapterStart = app.staticTexts["CHAPTER-02-START"].firstMatch
        XCTAssertTrue(chapterEnd.waitUntil(timeout: 20) {
            self.intersects(chapterEnd.frame, viewport.frame)
                && self.intersects(chapterStart.frame, viewport.frame)
                && chapterEnd.frame.maxX > chapterStart.frame.minX
                && chapterStart.frame.maxX > chapterEnd.frame.minX
        })
        XCTAssertLessThanOrEqual(chapterEnd.frame.maxY, chapterStart.frame.minY)

        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        XCTAssertTrue(reader.marker(.currentLocationMarker).contains("chapter-01.xhtml"))
        reader.runAction(.captureFirstVisible, completionPrefix: "captureFirstVisible")
        XCTAssertTrue(reader.marker(.firstVisibleMarker).contains("chapter-01.xhtml"))

        let secondResourceTarget = app.staticTexts["CHAPTER-02-START"].firstMatch
        XCTAssertTrue(secondResourceTarget.waitUntil(timeout: 10) {
            self.intersects(secondResourceTarget.frame, viewport.frame)
        })
        secondResourceTarget.tap()
        reader.runAction(.captureSelection, completionPrefix: "captureSelection")

        let selection = try geometry(from: reader.marker(.selectionMarker))
        XCTAssertTrue(reader.marker(.selectionMarker).contains("chapter-02.xhtml"))
        XCTAssertTrue(selection.rect.intersects(secondResourceTarget.frame))

        let decorationMarker = app.staticTexts[.decorationMarker].firstMatch
        XCTAssertTrue(decorationMarker.waitUntil(timeout: 10) {
            decorationMarker.label.contains("chapter-02.xhtml")
                && decorationMarker.label != "none"
        })
        let decoration = try geometry(from: decorationMarker.label)
        XCTAssertTrue(decoration.rect.intersects(secondResourceTarget.frame))
        XCTAssertTrue(secondResourceTarget.frame.contains(decoration.point))

        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        let continuousTitle = reader.marker(.titleMarker)
        viewport.swipeLeft()
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), continuousTitle)

        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), continuousTitle)

        reader.runAction(.jumpFragment, completionPrefix: "jumpFragment")
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        let titleBeforeTransition = reader.marker(.titleMarker)

        app.buttons[.testActions].tap()
        app.buttons[.toggleLayoutMode].tap()
        XCTAssertTrue(app.staticTexts[.actionMarker].waitUntil(timeout: 30) {
            self.app.staticTexts[.actionMarker].label.hasPrefix("done:toggleLayoutMode:")
        })
        let transition = reader.marker(.transitionMarker)
        XCTAssertTrue(transition.contains("moved=false"))
        XCTAssertTrue(transition.contains("before=Chapter 02"))
        XCTAssertTrue(transition.contains("after=Chapter 02"))
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), titleBeforeTransition)
        XCTAssertEqual(reader.marker(.modeMarker), "paged")

        reader.runAction(.jumpFirstResourceEnd, completionPrefix: "jumpFirstResourceEnd")
        XCTAssertTrue(reader.marker(.currentLocationMarker).contains("chapter-01.xhtml"))
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), "Chapter 01")

        let revisionBeforePageTurn = reader.marker(.locationRevisionMarker)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let locationRevisionMarker = app.staticTexts[.locationRevisionMarker].firstMatch
        XCTAssertTrue(locationRevisionMarker.waitUntil(timeout: 30) {
            locationRevisionMarker.label != revisionBeforePageTurn
                && locationRevisionMarker.label.contains("chapter-02.xhtml")
        })
        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), "Chapter 02")

        reader.close(assertMemoryDeallocated: true)
    }

    func testLocatorNavigationFirstVisibleAndScriptScope() {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        let viewport = reader.viewport

        reader.runAction(.jumpFragment, completionPrefix: "jumpFragment")
        let fragment = app.staticTexts["FRAGMENT-TARGET"].firstMatch
        XCTAssertTrue(fragment.waitUntil(timeout: 20) {
            self.intersects(fragment.frame, viewport.frame)
        })

        reader.runAction(.captureFirstVisible, completionPrefix: "captureFirstVisible")
        let firstVisible = reader.marker(.firstVisibleMarker)
        XCTAssertTrue(firstVisible.contains("chapter-02.xhtml"), firstVisible)
        XCTAssertTrue(firstVisible.contains("fragment-target"), firstVisible)

        reader.runAction(.jumpText, completionPrefix: "jumpText")
        let textTarget = app.staticTexts["UNIQUE TEXT QUOTE TARGET"].firstMatch
        XCTAssertTrue(textTarget.waitUntil(timeout: 20) {
            self.intersects(textTarget.frame, viewport.frame)
        })

        reader.runAction(.jumpTableOfContents, completionPrefix: "jumpTableOfContents", timeout: 60)
        let farTarget = app.staticTexts["CHAPTER-50-START"].firstMatch
        XCTAssertTrue(farTarget.waitUntil(timeout: 30) {
            self.intersects(farTarget.frame, viewport.frame)
        })

        reader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(reader.marker(.titleMarker), "Chapter 50")

        reader.close(assertMemoryDeallocated: true)
    }

    func testProgressionDynamicReflowAndMemoryRelease() throws {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        let viewport = reader.viewport

        reader.runAction(.jumpProgression10, completionPrefix: "jumpProgression10")
        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let tenPercent = try progression(from: reader.marker(.currentLocationMarker))
        XCTAssertLessThan(tenPercent, 0.25)

        let revisionMarker = app.staticTexts[.locationRevisionMarker].firstMatch
        var previousUpdate = try locationUpdate(from: revisionMarker.label)
        var userRevisions = Set<Int>()
        var userLocators = Set<String>()
        var finalProgression = tenPercent

        for _ in 0 ..< 40 where finalProgression < 0.8 {
            let previousLabel = revisionMarker.label
            viewport.swipeUp()
            XCTAssertTrue(revisionMarker.waitUntil(timeout: 10) {
                revisionMarker.label != previousLabel
            })

            let update = try locationUpdate(from: revisionMarker.label)
            XCTAssertGreaterThan(update.revision, previousUpdate.revision)
            XCTAssertTrue(update.locator.contains("chapter-03.xhtml"))
            userRevisions.insert(update.revision)
            userLocators.insert(update.locator)
            previousUpdate = update
            finalProgression = try progression(from: update.locator)
        }

        XCTAssertGreaterThanOrEqual(finalProgression, 0.8)
        XCTAssertGreaterThanOrEqual(userRevisions.count, 2)
        XCTAssertGreaterThanOrEqual(userLocators.count, 2)

        reader.runAction(.jumpReflowMarker, completionPrefix: "jumpReflowMarker")
        let reflowTarget = app.staticTexts[
            "REFLOW MARKER WITH ENOUGH WORDS TO WRAP ACROSS MULTIPLE LINES WHEN FONT SIZE AND LINE HEIGHT CHANGE DYNAMICALLY"
        ].firstMatch
        XCTAssertTrue(reflowTarget.waitUntil(timeout: 20) {
            self.intersects(reflowTarget.frame, viewport.frame)
        })
        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let anchorProgression = try progression(from: reader.marker(.currentLocationMarker))

        reader.runAction(.captureMetrics, completionPrefix: "captureMetrics")
        let beforeMetrics = try metrics(from: reader.marker(.metricsMarker))
        reader.runAction(.captureViewportMetrics, completionPrefix: "captureViewportMetrics")
        let beforeViewport = try viewportMetrics(from: reader.marker(.viewportMetricsMarker))
        let beforeTargetFrame = reflowTarget.frame
        let beforeAnchorPixel = beforeTargetFrame.midY - viewport.frame.minY

        reader.runAction(.applyTypography, completionPrefix: "applyTypography", timeout: 60)
        XCTAssertTrue(reflowTarget.waitUntil(timeout: 20) {
            reflowTarget.frame != beforeTargetFrame
                && self.intersects(reflowTarget.frame, viewport.frame)
        })
        reader.runAction(.captureMetrics, completionPrefix: "captureMetrics")
        let afterMetrics = try metrics(from: reader.marker(.metricsMarker))
        reader.runAction(.captureViewportMetrics, completionPrefix: "captureViewportMetrics")
        let afterViewport = try viewportMetrics(from: reader.marker(.viewportMetricsMarker))
        let afterAnchorPixel = reflowTarget.frame.midY - viewport.frame.minY
        let reflowEvidence = "beforeMetrics=\(beforeMetrics), afterMetrics=\(afterMetrics), beforeViewport=\(beforeViewport), afterViewport=\(afterViewport), beforeAnchorPixel=\(beforeAnchorPixel), afterAnchorPixel=\(afterAnchorPixel)"
        print("Continuous scroll evidence: finalProgression=\(finalProgression), revisions=\(userRevisions.count), locators=\(userLocators.count), \(reflowEvidence)")

        XCTAssertNotEqual(beforeMetrics.y, afterMetrics.y, accuracy: 0.5)
        XCTAssertNotEqual(beforeMetrics.height, afterMetrics.height, accuracy: 0.5)
        XCTAssertNotEqual(beforeViewport.offsetY, afterViewport.offsetY, accuracy: 0.5, reflowEvidence)
        XCTAssertEqual(beforeViewport.viewportHeight, afterViewport.viewportHeight, accuracy: 0.5, reflowEvidence)
        XCTAssertLessThanOrEqual(
            abs(beforeAnchorPixel - afterAnchorPixel),
            beforeViewport.viewportHeight * 0.05,
            reflowEvidence
        )

        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let grownProgression = try progression(from: reader.marker(.currentLocationMarker))
        XCTAssertEqual(grownProgression, anchorProgression, accuracy: 0.05, reflowEvidence)

        let grownTargetFrame = reflowTarget.frame
        reader.runAction(.shrinkTypography, completionPrefix: "shrinkTypography", timeout: 60)
        XCTAssertTrue(reflowTarget.waitUntil(timeout: 20) {
            reflowTarget.frame != grownTargetFrame
                && self.intersects(reflowTarget.frame, viewport.frame)
        })
        reader.runAction(.captureViewportMetrics, completionPrefix: "captureViewportMetrics")
        let shrunkViewport = try viewportMetrics(from: reader.marker(.viewportMetricsMarker))
        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let shrunkProgression = try progression(from: reader.marker(.currentLocationMarker))
        let shrunkAnchorPixel = reflowTarget.frame.midY - viewport.frame.minY
        let shrinkEvidence = "grownViewport=\(afterViewport), shrunkViewport=\(shrunkViewport), beforeAnchorPixel=\(beforeAnchorPixel), shrunkAnchorPixel=\(shrunkAnchorPixel), anchorProgression=\(anchorProgression), grownProgression=\(grownProgression), shrunkProgression=\(shrunkProgression)"

        XCTAssertGreaterThan(afterViewport.documentHeight, 0, shrinkEvidence)
        XCTAssertGreaterThan(shrunkViewport.documentHeight, 0, shrinkEvidence)
        XCTAssertLessThan(shrunkViewport.documentHeight, afterViewport.documentHeight, shrinkEvidence)
        XCTAssertLessThan(shrunkViewport.spreadHeight, afterViewport.spreadHeight, shrinkEvidence)
        XCTAssertEqual(
            shrunkViewport.spreadHeight,
            shrunkViewport.documentHeight,
            accuracy: 1,
            shrinkEvidence
        )
        XCTAssertLessThanOrEqual(
            abs(beforeAnchorPixel - shrunkAnchorPixel),
            shrunkViewport.viewportHeight * 0.05,
            shrinkEvidence
        )
        XCTAssertEqual(shrunkProgression, anchorProgression, accuracy: 0.05, shrinkEvidence)

        reader.close(assertMemoryDeallocated: true)
    }

    private func intersects(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        !lhs.isEmpty && !rhs.isEmpty && lhs.intersects(rhs)
    }

    private func progression(from marker: String) throws -> Double {
        let value = marker
            .split(separator: "|")
            .first(where: { $0.hasPrefix("p=") })?
            .dropFirst(2)
        return try XCTUnwrap(value.flatMap { Double($0) })
    }

    private func locationUpdate(from marker: String) throws -> (revision: Int, locator: String) {
        let separator = try XCTUnwrap(marker.firstIndex(of: "|"))
        let revision = marker[..<separator].dropFirst(2)
        return (
            revision: try XCTUnwrap(Int(revision)),
            locator: String(marker[marker.index(after: separator)...])
        )
    }

    private func metrics(from marker: String) throws -> (y: Double, height: Double) {
        let values = metricsValues(from: marker)
        return (
            y: try XCTUnwrap(values["y"]),
            height: try XCTUnwrap(values["h"])
        )
    }

    private func metricsValues(from marker: String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: marker.split(separator: "|").compactMap { component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        })
    }

    private func viewportMetrics(from marker: String) throws -> (
        offsetY: Double,
        viewportHeight: Double,
        documentHeight: Double,
        spreadHeight: Double
    ) {
        let pairs: [(String, Double)] = marker.split(separator: "|").compactMap { component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        return (
            offsetY: try XCTUnwrap(values["offsetY"]),
            viewportHeight: try XCTUnwrap(values["viewportHeight"]),
            documentHeight: try XCTUnwrap(values["documentHeight"]),
            spreadHeight: try XCTUnwrap(values["spreadHeight"])
        )
    }

    private func geometry(from marker: String) throws -> (rect: CGRect, point: CGPoint) {
        let pairs: [(String, Double)] = marker.split(separator: "|").compactMap { component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        let rect = CGRect(
            x: try XCTUnwrap(values["x"]),
            y: try XCTUnwrap(values["y"]),
            width: try XCTUnwrap(values["w"]),
            height: try XCTUnwrap(values["h"])
        )
        let point = CGPoint(
            x: values["px"] ?? rect.midX,
            y: values["py"] ?? rect.midY
        )
        return (rect, point)
    }
}
