//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

final class NavigationStressTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Exercises the continuous 50-resource fixture with a reproducible mix of
    /// Locator jumps and real vertical drags. A crash fails the test
    /// automatically, including `WKURLSchemeTask` cancellation races.
    /// See https://github.com/readium/r2-navigator-swift/pull/160
    func testContinuousNavigationStressRestoresAndDeallocates() throws {
        let reader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        let viewport = reader.viewport
        let actionMarker = app.staticTexts[.actionMarker].firstMatch
        let locationRevisionMarker = app.staticTexts[.locationRevisionMarker].firstMatch

        app.buttons[.testActions].tap()
        let stressButton = app.buttons[.runStressTest].firstMatch
        XCTAssertTrue(stressButton.waitForExistence(timeout: 5))
        stressButton.tap()

        var handledDragMarker = ""
        while true {
            XCTAssertTrue(actionMarker.waitUntil(timeout: 120) {
                let marker = actionMarker.label
                return marker.hasPrefix("done:continuousStress:")
                    || marker.hasPrefix("failed:continuousStress:")
                    || (marker.hasPrefix("drag:continuousStress:") && marker != handledDragMarker)
            })

            let marker = actionMarker.label
            if marker.hasPrefix("done:continuousStress:") {
                break
            }
            if marker.hasPrefix("failed:continuousStress:") {
                XCTFail(marker)
                return
            }

            let direction = try XCTUnwrap(marker.split(separator: "|").last)
            let revisionBeforeDrag = locationRevisionMarker.label
            let startY = direction == "up" ? 0.8 : 0.2
            let endY = direction == "up" ? 0.2 : 0.8
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(
                    forDuration: 0.01,
                    thenDragTo: viewport.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                    )
                )
            XCTAssertTrue(locationRevisionMarker.waitUntil(timeout: 30) {
                locationRevisionMarker.label != revisionBeforeDrag
            })
            handledDragMarker = marker
        }

        app.switches[.stressTestCompleted].assertIs(true, waitForTimeout: 30)
        let summary = actionMarker.label
        XCTAssertTrue(summary.contains("seed=12648430"), summary)
        let counts = try ["toc", "fragment", "text", "progression", "drag"]
            .map { try summaryValue($0, in: summary) }
        XCTAssertEqual(counts.reduce(0, +), 100, summary)
        counts.forEach { XCTAssertGreaterThan($0, 0, summary) }

        reader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let beforeLocator = reader.marker(.currentLocationMarker)
        XCTAssertTrue(beforeLocator.contains("chapter-02.xhtml"), beforeLocator)
        XCTAssertEqual(try progression(from: beforeLocator), 0.5, accuracy: 0.03, beforeLocator)
        reader.runAction(.captureViewportMetrics, completionPrefix: "captureViewportMetrics")
        let before = try viewportMetrics(from: reader.marker(.viewportMetricsMarker))

        reader.close(assertMemoryDeallocated: true)

        let reopenedReader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        reopenedReader.runAction(.captureCurrentLocation, completionPrefix: "captureCurrentLocation")
        let afterLocator = reopenedReader.marker(.currentLocationMarker)
        XCTAssertTrue(afterLocator.contains("chapter-02.xhtml"), afterLocator)
        XCTAssertEqual(try progression(from: afterLocator), 0.5, accuracy: 0.03, afterLocator)
        reopenedReader.runAction(.captureViewportMetrics, completionPrefix: "captureViewportMetrics")
        let after = try viewportMetrics(from: reopenedReader.marker(.viewportMetricsMarker))
        let evidence = "before=\(before), after=\(after)"
        XCTAssertEqual(before.viewportHeight, after.viewportHeight, accuracy: 0.5, evidence)
        XCTAssertLessThanOrEqual(
            abs(before.offsetY - after.offsetY),
            before.viewportHeight * 0.05,
            evidence
        )

        reopenedReader.close(assertMemoryDeallocated: true)
    }

    private func summaryValue(_ key: String, in marker: String) throws -> Int {
        let value = marker
            .split(separator: "|")
            .first(where: { $0.hasPrefix("\(key)=") })?
            .split(separator: "=", maxSplits: 1)
            .last
        return try XCTUnwrap(value.flatMap { Int($0) })
    }

    private func progression(from marker: String) throws -> Double {
        let value = marker
            .split(separator: "|")
            .first(where: { $0.hasPrefix("p=") })?
            .dropFirst(2)
        return try XCTUnwrap(value.flatMap { Double($0) })
    }

    private func viewportMetrics(from marker: String) throws -> (offsetY: Double, viewportHeight: Double) {
        let pairs: [(String, Double)] = marker.split(separator: "|").compactMap { component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        return (
            offsetY: try XCTUnwrap(values["offsetY"]),
            viewportHeight: try XCTUnwrap(values["viewportHeight"])
        )
    }
}
