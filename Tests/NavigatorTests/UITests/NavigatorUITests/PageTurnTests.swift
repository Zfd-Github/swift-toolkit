//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

final class PageTurnTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testNonePreservesWebInteractions() throws {
        let reader = app.open(.childrensLiteratureEPUB, waitUntilReady: true)
        let viewport = reader.viewport
        let location = app.staticTexts[.locationRevisionMarker].firstMatch
        let begin = app.staticTexts["pageTurnBeginMarker"].firstMatch
        let tap = app.staticTexts["pageTurnTapMarker"].firstMatch
        let link = app.staticTexts["pageTurnLinkMarker"].firstMatch

        XCTAssertEqual(count(in: begin.label), 0)
        let initialLocation = try revision(in: location.label)

        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(tap.waitUntil(timeout: 10) {
            self.count(in: tap.label) == 1
        })
        XCTAssertEqual(count(in: begin.label), 0)
        XCTAssertEqual(try revision(in: location.label), initialLocation)

        drag(
            viewport,
            from: CGVector(dx: 0.55, dy: 0.8),
            to: CGVector(dx: 0.45, dy: 0.2)
        )
        waitForGestureSettlement()
        XCTAssertEqual(count(in: begin.label), 0)
        XCTAssertEqual(try revision(in: location.label), initialLocation)

        viewport.swipeLeft()
        XCTAssertTrue(location.waitUntil(timeout: 20) {
            (try? self.revision(in: location.label)) == initialLocation + 1
                && location.label.contains("nav.xhtml")
        }, location.label)
        XCTAssertEqual(count(in: begin.label), 1)

        let sectionLink = app.links.matching(
            NSPredicate(format: "label CONTAINS %@", "SECTION IV FAIRY STORIES")
        ).firstMatch
        XCTAssertTrue(sectionLink.waitForExistence(timeout: 20))
        let beforeLink = try revision(in: location.label)
        sectionLink.tap()
        XCTAssertTrue(link.waitUntil(timeout: 20) {
            self.count(in: link.label) == 1
        })
        XCTAssertTrue(location.waitUntil(timeout: 20) {
            (try? self.revision(in: location.label)) == beforeLink + 1
                && location.label.contains("s04.xhtml")
        }, location.label)
        XCTAssertEqual(count(in: begin.label), 1)

        let selectionTarget = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "The difficulties of classification")
        ).firstMatch
        XCTAssertTrue(selectionTarget.waitForExistence(timeout: 20))
        selectionTarget.press(forDuration: 1)
        let selection = app.staticTexts[.selectionMarker].firstMatch
        XCTAssertTrue(selection.waitUntil(timeout: 20) {
            selection.label.contains("s04.xhtml")
        }, selection.label)
        XCTAssertEqual(count(in: begin.label), 1)

        let beforeSelectionPan = location.label
        let beforeSelectionSample = selection.label
        drag(
            viewport,
            from: CGVector(dx: 0.8, dy: 0.5),
            to: CGVector(dx: 0.2, dy: 0.5)
        )
        waitForGestureSettlement()
        XCTAssertEqual(count(in: begin.label), 1)
        XCTAssertEqual(location.label, beforeSelectionPan)
        XCTAssertTrue(selection.waitUntil(timeout: 10) {
            selection.label != beforeSelectionSample
                && selection.label.contains("s04.xhtml")
        }, selection.label)

        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        waitForGestureSettlement()
        reader.close(assertMemoryDeallocated: true)

        let continuousReader = app.open(.continuousScrollEPUB, waitUntilReady: true)
        continuousReader.runAction(.captureTitle, completionPrefix: "captureTitle")
        let continuousTitle = continuousReader.marker(.titleMarker)
        let continuousLocation = continuousReader.marker(.locationRevisionMarker)
        continuousReader.viewport.swipeLeft()
        waitForGestureSettlement()
        continuousReader.runAction(.captureTitle, completionPrefix: "captureTitle")
        XCTAssertEqual(continuousReader.marker(.titleMarker), continuousTitle)
        XCTAssertEqual(continuousReader.marker(.locationRevisionMarker), continuousLocation)
        continuousReader.close(assertMemoryDeallocated: true)
    }

    private func drag(
        _ element: XCUIElement,
        from start: CGVector,
        to end: CGVector
    ) {
        element.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: element.coordinate(withNormalizedOffset: end)
        )
    }

    private func count(in marker: String) -> Int {
        Int(marker.split(separator: "=").last ?? "-1") ?? -1
    }

    private func revision(in marker: String) throws -> Int {
        let component = marker.split(separator: "|").first
        return try XCTUnwrap(component.flatMap { Int($0.dropFirst(2)) })
    }

    private func waitForGestureSettlement() {
        let expectation = expectation(description: "gesture settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
