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

    func testSnapshotProbe() throws {
        for fixture in [PublicationFixture.pageTurnProbeLTR, .pageTurnProbeRTL] {
            let normalReader = app.open(fixture, waitUntilReady: true)
            normalReader.runAction(
                .captureSnapshotProbe,
                completionPrefix: "captureSnapshotProbe",
                timeout: 300
            )
            let normal = normalReader.marker(.snapshotProbeMarker)
            XCTAssertTrue(normal.contains("normal=true"), normal)
            XCTAssertTrue(normal.contains("sameLeft=50"), normal)
            XCTAssertTrue(normal.contains("sameRight=50"), normal)
            XCTAssertTrue(normal.contains("crossLeft=50"), normal)
            XCTAssertTrue(normal.contains("crossRight=50"), normal)
            XCTAssertTrue(normal.contains("themeMiss=true"), normal)
            XCTAssertTrue(normal.contains("layoutMiss=true"), normal)
            assertExpectedSnapshotColors(in: normal, isRTL: fixture == .pageTurnProbeRTL)
            normalReader.close(assertMemoryDeallocated: true)

            let selectionReader = app.open(fixture, waitUntilReady: true)
            let selectionTarget = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Selectable PAGE-A text")
            ).firstMatch
            XCTAssertTrue(selectionTarget.waitUntil(timeout: 30) { selectionTarget.isHittable })
            selectionTarget.press(forDuration: 1)
            let selectionEvidence = app.staticTexts[.selectionMarker].firstMatch
            XCTAssertTrue(selectionEvidence.waitUntil(timeout: 20) {
                !selectionEvidence.label.contains("none")
            }, selectionEvidence.label)
            selectionReader.runAction(
                .captureSnapshotSelectionProbe,
                completionPrefix: "captureSnapshotSelectionProbe",
                timeout: 60
            )
            let selection = selectionReader.marker(.snapshotProbeMarker)
            XCTAssertTrue(selection.contains("selectionBeforeNonEmpty=true"), selection)
            XCTAssertTrue(selection.contains("selectionNil=true"), selection)
            XCTAssertTrue(selection.contains("selectionSame=true"), selection)
            XCTAssertTrue(selection.contains("offsetSame=true"), selection)
            XCTAssertTrue(selection.contains("progressionSame=true"), selection)
            XCTAssertTrue(selection.contains("textSame=true"), selection)
            XCTAssertTrue(selection.contains("locationDelta=0"), selection)
            selectionReader.close(assertMemoryDeallocated: true)

            let mediaReader = app.open(fixture, waitUntilReady: true)
            let playVideo = app.buttons.matching(
                NSPredicate(format: "label == %@", "Play probe video")
            ).firstMatch
            XCTAssertTrue(playVideo.waitForExistence(timeout: 30))
            mediaReader.runAction(
                .captureSnapshotMediaProbe,
                completionPrefix: "captureSnapshotMediaProbe",
                timeout: 60,
                afterStart: { playVideo.tap() }
            )
            let media = mediaReader.marker(.snapshotProbeMarker)
            XCTAssertTrue(media.contains("mediaBefore=true"), media)
            XCTAssertTrue(media.contains("mediaNil=true"), media)
            XCTAssertTrue(media.contains("mediaSame=true"), media)
            XCTAssertTrue(media.contains("offsetSame=true"), media)
            XCTAssertTrue(media.contains("progressionSame=true"), media)
            XCTAssertTrue(media.contains("textSame=true"), media)
            XCTAssertTrue(media.contains("locationDelta=0"), media)
            dismissMediaOverlayIfNeeded(waitForExistence: 10)
            mediaReader.close(assertMemoryDeallocated: true)
        }
    }

    func testCover() throws {
        for fixture in [PublicationFixture.pageTurnProbeLTR, .pageTurnProbeRTL] {
            let isRTL = fixture == .pageTurnProbeRTL
            let reader = app.open(fixture, waitUntilReady: true)
            let viewport = reader.viewport
            let location = app.staticTexts[.locationRevisionMarker].firstMatch

            reader.runAction(.prepareCoverProbe, completionPrefix: "prepareCoverProbe")
            let initialRevision = try revision(in: location.label)

            edgeTap(viewport, forward: true, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == initialRevision + 1
            }, location.label)
            assertCoverState(reader, marker: "PAGE-B")

            edgeTap(viewport, forward: false, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == initialRevision + 2
            }, location.label)
            assertCoverState(reader, marker: "PAGE-A")

            reader.runAction(
                .awaitCoverForwardReady,
                completionPrefix: "awaitCoverForwardReady"
            )
            let coverBeforeSwipe = reader.marker(.coverProbeMarker)
            swipe(viewport, forward: true, isRTL: isRTL)
            let didSwipeForward = location.waitUntil(timeout: 5) {
                (try? self.revision(in: location.label)) == initialRevision + 3
            }
            if !didSwipeForward {
                reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
            }
            XCTAssertTrue(
                didSwipeForward,
                "location=\(location.label)|coverBefore=\(coverBeforeSwipe)|coverAfter=\(reader.marker(.coverProbeMarker))"
            )
            assertCoverState(reader, marker: "PAGE-B", requiresTracking: true)

            reader.runAction(
                .awaitCoverBackwardReady,
                completionPrefix: "awaitCoverBackwardReady"
            )
            swipe(viewport, forward: false, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == initialRevision + 4
            }, location.label)
            assertCoverState(reader, marker: "PAGE-A", requiresTracking: true)

            reader.runAction(
                .awaitCoverForwardReady,
                completionPrefix: "awaitCoverForwardReady"
            )
            let beforeCancel = location.label
            shortDrag(viewport, forward: true, isRTL: isRTL)
            assertCoverState(
                reader,
                marker: "PAGE-A",
                requiresTracking: true,
                committed: false
            )
            XCTAssertEqual(location.label, beforeCancel)
            edgeTap(viewport, forward: true, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == initialRevision + 5
            }, location.label)

            reader.runAction(
                .awaitCoverForwardReady,
                completionPrefix: "awaitCoverForwardReady"
            )
            swipe(viewport, forward: true, isRTL: isRTL)
            swipe(viewport, forward: false, isRTL: isRTL)
            reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
            let afterRapidReverse = try revision(in: location.label)
            edgeTap(viewport, forward: false, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == afterRapidReverse + 1
            }, location.label)

            reader.runAction(.prepareCoverCrossResource, completionPrefix: "prepareCoverCrossResource")
            reader.runAction(
                .awaitCoverForwardReady,
                completionPrefix: "awaitCoverForwardReady"
            )
            let beforeCrossResource = try revision(in: location.label)
            swipe(viewport, forward: true, isRTL: isRTL)
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == beforeCrossResource + 1
                    && location.label.contains("second.xhtml")
            }, location.label)
            assertCoverState(reader, marker: "RESOURCE-2", requiresTracking: true)

            reader.runAction(.prepareCoverProbe, completionPrefix: "prepareCoverProbe")
            let selectionTarget = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Selectable PAGE-A text")
            ).firstMatch
            XCTAssertTrue(selectionTarget.waitUntil(timeout: 20) { selectionTarget.isHittable })
            selectionTarget.press(forDuration: 1)
            let copyMenuItem = app.menuItems["Copy"].firstMatch
            XCTAssertTrue(copyMenuItem.waitForExistence(timeout: 10))
            let beforeSelection = location.label
            swipe(viewport, forward: true, isRTL: isRTL)
            XCTAssertEqual(location.label, beforeSelection)
            let copyMenuButton = app.buttons["Copy"].firstMatch
            XCTAssertTrue(copyMenuItem.waitUntil(timeout: 5) {
                copyMenuItem.exists || copyMenuButton.exists
            })
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap()
            XCTAssertTrue(copyMenuItem.waitUntil(timeout: 5) {
                !copyMenuItem.exists && !copyMenuButton.exists
            })
            XCTAssertEqual(location.label, beforeSelection)
            reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
            let selectionMarker = reader.marker(.coverProbeMarker)
            XCTAssertTrue(selectionMarker.contains("overlayCount=0"), selectionMarker)
            XCTAssertTrue(selectionMarker.contains("overlaySamples=0"), selectionMarker)

            let playVideo = app.buttons.matching(
                NSPredicate(format: "label == %@", "Play probe video")
            ).firstMatch
            XCTAssertTrue(playVideo.waitForExistence(timeout: 20))
            reader.runAction(
                .startCoverMediaProbe,
                completionPrefix: "startCoverMediaProbe",
                timeout: 30,
                afterStart: { playVideo.tap() }
            )
            let activeMedia = app.staticTexts[.activeMediaMarker].firstMatch
            XCTAssertTrue(activeMedia.waitUntil(timeout: 10) {
                activeMedia.label.contains("active=true")
            }, activeMedia.label)
            let beforeMedia = location.label
            swipe(viewport, forward: true, isRTL: isRTL)
            let activeMediaSampleAfterSwipe = markerSample(in: activeMedia.label)
            XCTAssertEqual(location.label, beforeMedia)
            let mediaPresentation = app.otherElements["Media"].firstMatch
            XCTAssertTrue(mediaPresentation.waitForExistence(timeout: 10))
            XCTAssertTrue(activeMedia.waitUntil(timeout: 10) {
                self.markerSample(in: activeMedia.label) > activeMediaSampleAfterSwipe
                    && activeMedia.label.contains("active=true")
            }, activeMedia.label)
            XCTAssertEqual(location.label, beforeMedia)
            dismissMediaOverlayIfNeeded(waitForExistence: 10)
            XCTAssertEqual(location.label, beforeMedia)
            reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
            let mediaMarker = reader.marker(.coverProbeMarker)
            XCTAssertTrue(mediaMarker.contains("overlayCount=0"), mediaMarker)
            XCTAssertTrue(mediaMarker.contains("overlaySamples=0"), mediaMarker)
            reader.runAction(.stopCoverMediaProbe, completionPrefix: "stopCoverMediaProbe")
            reader.close(assertMemoryDeallocated: true)
        }

        for fixture in [PublicationFixture.pageTurnProbeReduceMotion, .pageTurnProbeVoiceOver] {
            let reader = app.open(fixture, waitUntilReady: true)
            reader.runAction(.prepareCoverProbe, completionPrefix: "prepareCoverProbe")
            let location = app.staticTexts[.locationRevisionMarker].firstMatch
            let before = try revision(in: location.label)
            reader.viewport.swipeLeft()
            XCTAssertTrue(location.waitUntil(timeout: 20) {
                (try? self.revision(in: location.label)) == before + 1
            }, location.label)
            reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
            let marker = reader.marker(.coverProbeMarker)
            XCTAssertTrue(marker.contains("overlayCount=0"), marker)
            XCTAssertTrue(marker.contains("overlaySamples=0"), marker)
            reader.close(assertMemoryDeallocated: true)
        }
    }

    private func assertCoverState(
        _ reader: ReaderUI,
        marker expectedMarker: String,
        requiresTracking: Bool = false,
        committed: Bool = true
    ) {
        reader.runAction(.captureCoverProbe, completionPrefix: "captureCoverProbe")
        let marker = reader.marker(.coverProbeMarker)
        XCTAssertTrue(marker.contains("visible=\(expectedMarker)"), marker)
        XCTAssertTrue(marker.contains("overlayCount=0"), marker)
        XCTAssertTrue(marker.contains("locationDelta=\(committed ? 1 : 0)"), marker)
        XCTAssertTrue(marker.contains("locationDuringOverlay=\(committed ? 1 : 0)"), marker)
        if requiresTracking {
            XCTAssertFalse(marker.contains("overlaySamples=0"), marker)
            XCTAssertTrue(marker.contains("tracked=true"), marker)
            XCTAssertTrue(marker.contains("progressed=true"), marker)
        }
    }

    private func edgeTap(_ viewport: XCUIElement, forward: Bool, isRTL: Bool) {
        let usesRightEdge = forward != isRTL
        viewport.coordinate(
            withNormalizedOffset: CGVector(dx: usesRightEdge ? 0.96 : 0.04, dy: 0.5)
        ).tap()
    }

    private func swipe(_ viewport: XCUIElement, forward: Bool, isRTL: Bool) {
        let swipesLeft = forward != isRTL
        if swipesLeft {
            viewport.swipeLeft()
        } else {
            viewport.swipeRight()
        }
    }

    private func shortDrag(_ viewport: XCUIElement, forward: Bool, isRTL: Bool) {
        let movesLeft = forward != isRTL
        drag(
            viewport,
            from: CGVector(dx: movesLeft ? 0.6 : 0.4, dy: 0.5),
            to: CGVector(dx: movesLeft ? 0.52 : 0.48, dy: 0.5)
        )
    }

    private func assertExpectedSnapshotColors(in marker: String, isRTL: Bool) {
        let expectations = isRTL
            ? [
                "sameLeft=50,color=#8A00B8",
                "sameRight=50,color=#0057D9",
                "crossLeft=50,color=#5A3A00",
                "crossRight=50,color=#B34B00",
            ]
            : [
                "sameLeft=50,color=#0057D9",
                "sameRight=50,color=#8A00B8",
                "crossLeft=50,color=#B34B00",
                "crossRight=50,color=#5A3A00",
            ]
        for expectation in expectations {
            XCTAssertTrue(marker.contains(expectation), marker)
        }
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

    private func dismissMediaOverlayIfNeeded(
        waitForExistence timeout: TimeInterval = 0
    ) {
        let media = app.otherElements["Media"].firstMatch
        guard media.waitForExistence(timeout: timeout) else {
            return
        }
        media.tap()

        let close = app.buttons["Close Button"].firstMatch
        guard close.waitForExistence(timeout: 5) else {
            XCTFail("Media overlay close control did not appear")
            return
        }
        close.tap()
        XCTAssertTrue(
            close.waitForNonExistence(timeout: 10),
            "Media overlay did not close"
        )
        XCTAssertTrue(
            media.waitForNonExistence(timeout: 10),
            "Media presentation did not disappear"
        )
    }

    private func revision(in marker: String) throws -> Int {
        let component = marker.split(separator: "|").first
        return try XCTUnwrap(component.flatMap { Int($0.dropFirst(2)) })
    }

    private func markerSample(in marker: String) -> Int {
        let sample = marker.split(separator: "|").first
        return Int(sample?.split(separator: "=").last ?? "-1") ?? -1
    }

    private func waitForGestureSettlement() {
        let expectation = expectation(description: "gesture settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
