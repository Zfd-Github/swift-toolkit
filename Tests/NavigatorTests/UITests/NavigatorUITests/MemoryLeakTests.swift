//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

/// These tests verify that navigator instances are properly deallocated when
/// dismissed.
///
/// The host app maintains a weak reference to the navigator. If the navigator
/// is properly deallocated after dismissal, the weak reference becomes nil.
/// If it remains non-nil, a retain cycle or memory leak exists.
final class MemoryLeakTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testEPUBNavigatorDeallocatesAfterClosing() {
        app
            .open(.childrensLiteratureEPUB, waitUntilReady: true)
            .close(assertMemoryDeallocated: true)
    }

    func testEPUBNavigatorDeallocatesAfterClosingBeforeReady() {
        app
            .open(.childrensLiteratureEPUB, waitUntilReady: false)
            .close(assertMemoryDeallocated: true)
    }

    func testContinuousEPUBNavigatorDeallocatesAfterClosing() {
        let reader = app.open(.continuousScrollFailedNeighborEPUB, waitUntilReady: true)

        reader.runAction(
            .toggleLayoutModeWithFailedNeighbor,
            completionPrefix: "toggleLayoutModeWithFailedNeighbor",
            timeout: 60
        )

        let transition = reader.marker(.transitionMarker)
        XCTAssertTrue(transition.contains("scroll=false"), transition)
        XCTAssertTrue(transition.contains("oldPaginationReleased=true"), transition)
        XCTAssertTrue(transition.contains("oldWebViewsReleased=true"), transition)
        XCTAssertTrue(transition.contains("tokenPreserved=false"), transition)
        XCTAssertTrue(transition.contains("targetReached=true"), transition)
        XCTAssertTrue(transition.contains("target=Chapter 03"), transition)
        XCTAssertTrue(transition.contains("originalReached=true"), transition)
        XCTAssertTrue(transition.contains("original=Chapter 01"), transition)
        XCTAssertEqual(reader.marker(.modeMarker), "paged")

        reader.close(assertMemoryDeallocated: true)
    }

    func testPDFNavigatorDeallocatesAfterClosing() {
        app
            .open(.daisyPDF, waitUntilReady: true)
            .close(assertMemoryDeallocated: true)
    }

    func testPDFNavigatorDeallocatesAfterClosingBeforeReady() {
        app
            .open(.daisyPDF, waitUntilReady: false)
            .close(assertMemoryDeallocated: true)
    }
}
