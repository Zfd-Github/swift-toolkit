//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

extension XCUIApplication {
    /// Opens a publication fixture.
    @discardableResult
    func open(_ fixture: PublicationFixture, waitUntilReady: Bool = true) -> ReaderUI {
        staticTexts[fixture.accessibilityIdentifier].firstMatch.tap()

        let reader = ReaderUI(app: self)

        if waitUntilReady {
            // Give the navigator time to fully load content.
            reader.assertReady()
        }

        return reader
    }

    /// Checks that some memory is allocated in the app.
    @discardableResult
    func assertSomeMemoryAllocated() -> Self {
        switches[.allMemoryDeallocated].assertIs(false)
        return self
    }

    /// Checks that all the tracked memory is deallocated in the app.
    ///
    /// A timeout is used to make sure the memory is cleared.
    @discardableResult
    func assertAllMemoryDeallocated() -> Self {
        switches[.allMemoryDeallocated].assertIs(true, waitForTimeout: 120)
        return self
    }
}

struct ReaderUI {
    let app: XCUIApplication

    var viewport: XCUIElement {
        app.otherElements[.readerViewport].firstMatch
    }

    /// Activates the Close button.
    @discardableResult
    func close(assertMemoryDeallocated: Bool = true) -> XCUIApplication {
        app.buttons[.close].tap()
        if assertMemoryDeallocated {
            app.assertAllMemoryDeallocated()
        }
        return app
    }

    /// Waits for the navigator to be ready.
    @discardableResult
    func assertReady(timeout: TimeInterval = 30) -> Self {
        app.switches[.isNavigatorReady].assertIs(true, waitForTimeout: timeout)
        return self
    }

    @discardableResult
    func runAction(
        _ action: AccessibilityID,
        completionPrefix: String,
        timeout: TimeInterval = 30
    ) -> Self {
        let marker = app.staticTexts[.actionMarker].firstMatch
        let previous = marker.label

        app.buttons[.testActions].tap()
        switch action {
        case .jumpMissingResource,
             .jumpFirstResourceEnd,
             .jumpFragment,
             .jumpText,
             .jumpTableOfContents,
             .jumpProgression10,
             .jumpProgression80,
             .jumpReflowMarker:
            openActionGroup(.navigationActions)

        case .captureCurrentLocation,
             .captureFirstVisible,
             .captureMetrics,
             .captureViewportMetrics,
             .captureTitle,
             .captureSelection:
            openActionGroup(.captureActions)

        default:
            break
        }
        let button = app.buttons[action].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing test action \(action.rawValue)")
        button.tap()

        let predicate = NSPredicate { _, _ in
            marker.label.hasPrefix("done:\(completionPrefix):") && marker.label != previous
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: marker)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Last action marker: \(marker.label)")
        return self
    }

    func marker(_ id: AccessibilityID) -> String {
        app.staticTexts[id].firstMatch.label
    }

    private func openActionGroup(_ id: AccessibilityID) {
        let group = app.buttons[id].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), "Missing test action group \(id.rawValue)")
        group.tap()
    }
}
