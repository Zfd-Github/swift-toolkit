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
        let memorySwitch = switches[.allMemoryDeallocated].firstMatch
        let fixtureList = collectionViews.firstMatch
        let didScroll = !memorySwitch.exists && fixtureList.exists
        if didScroll {
            fixtureList.swipeUp()
        }
        defer {
            if didScroll {
                fixtureList.swipeDown()
            }
        }
        guard memorySwitch.waitForExistence(timeout: 5) else {
            XCTFail("Missing memory-deallocation indicator")
            return self
        }
        memorySwitch.assertIs(true, waitForTimeout: 120)
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
        timeout: TimeInterval = 30,
        afterStart: (() -> Void)? = nil
    ) -> Self {
        let previous = app.staticTexts[.actionMarker].firstMatch.label
        let button = app.buttons[action].firstMatch

        let testActions = app.buttons[.testActions].firstMatch
        if testActions.exists {
            testActions.tap()
        } else {
            let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 5), "Missing toolbar overflow")
            overflow.tap()
            if !button.waitForExistence(timeout: 1) {
                if testActions.waitForExistence(timeout: 1) {
                    testActions.tap()
                } else {
                    let toolbarGroup = app.buttons["Run Stress Test"].firstMatch
                    if toolbarGroup.waitForExistence(timeout: 1) {
                        toolbarGroup.tap()
                    }
                }
            }
        }
        if !button.waitForExistence(timeout: 1) {
            switch action {
            case .jumpMissingResource,
                 .jumpFirstResourceEnd,
                 .jumpFragment,
                 .jumpText,
                 .jumpTableOfContents,
                 .jumpProgression10,
                 .jumpProgression80,
                 .jumpReflowMarker:
                openActionGroupIfPresent(.navigationActions)

            case .captureCurrentLocation,
                 .captureFirstVisible,
                 .captureMetrics,
                 .captureViewportMetrics,
                 .captureTitle,
                 .captureSelection:
                openActionGroupIfPresent(.captureActions)

            default:
                break
            }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing test action \(action.rawValue)")
        button.tap()

        let actionStates = afterStart == nil
            ? ["running", "done", "failed"]
            : ["running"]
        let actionPrefixes = actionStates
            .map { "\($0):\(completionPrefix):" }
        var generation: String?
        let generationPredicate = NSPredicate { _, _ in
            let current = app.staticTexts[.actionMarker].firstMatch.label
            guard current != previous else { return false }
            for prefix in actionPrefixes where current.hasPrefix(prefix) {
                generation = String(
                    current.dropFirst(prefix.count)
                        .split(whereSeparator: { $0 == ":" || $0 == "|" })[0]
                )
                return true
            }
            return false
        }
        let generationExpectation = XCTNSPredicateExpectation(
            predicate: generationPredicate,
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [generationExpectation], timeout: 5),
            .completed,
            "Action did not start: \(app.staticTexts[.actionMarker].firstMatch.label)"
        )
        guard let generation else { return self }
        afterStart?()

        let doneMarker = "done:\(completionPrefix):\(generation)"
        let failedPrefix = "failed:\(completionPrefix):\(generation):"
        let predicate = NSPredicate { _, _ in
            let current = app.staticTexts[.actionMarker].firstMatch.label
            return current == doneMarker || current.hasPrefix(failedPrefix)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let marker = app.staticTexts[.actionMarker].firstMatch.label
        XCTAssertEqual(
            result,
            .completed,
            "Last action marker: \(marker); snapshot probe: \(self.marker(.snapshotProbeMarker))"
        )
        XCTAssertEqual(
            marker,
            doneMarker,
            "Action failed: \(marker); snapshot probe: \(self.marker(.snapshotProbeMarker))"
        )
        return self
    }

    func marker(_ id: AccessibilityID) -> String {
        app.staticTexts[id].firstMatch.label
    }

    private func openActionGroupIfPresent(_ id: AccessibilityID) {
        let group = app.buttons[id].firstMatch
        if group.waitForExistence(timeout: 1) {
            group.tap()
        }
    }
}
