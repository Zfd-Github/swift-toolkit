//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class PublicationSpeechSynthesizerTests: XCTestCase {
    func testPrefetchesForwardUtteranceWithoutAdvancingPlaybackState() async throws {
        let first = textElement("first", href: "first.xhtml")
        let second = textElement("second", href: "second.xhtml")
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [first, second],
            engine: engine
        )

        synthesizer.start()

        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                engine.prefetchedTexts.first == "second"
        }
        guard case let .playing(utterance, range) = synthesizer.state else {
            return XCTFail("Expected the first utterance to remain current")
        }
        XCTAssertEqual(utterance.text, "first")
        XCTAssertEqual(range?.href, first.locator.href)
        XCTAssertEqual(engine.spokenTexts, ["first"])

        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testAutomaticContinuationWaitsForPendingPrefetchAndReusesIt() async throws {
        // Three utterances: second is the "next" waterline item; third stays
        // deferred so an incorrect `await forwardPrefetchTask.value` would hang
        // before speaking second (or never reach the mid-play assertions).
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        let secondPrefetchIdentifier = try XCTUnwrap(engine.prefetchedIdentifiers.last)
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }

        // While second is still pending: no cancel, no early speak(second).
        XCTAssertEqual(engine.spokenTexts, ["first"])
        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        XCTAssertTrue(engine.hasPendingPrefetch)

        // Complete only the second look-ahead item. Forward continues and hangs
        // on third — proving we do not wait for the full waterline task.
        engine.completePrefetch()
        try await waitUntil {
            engine.spokenTexts == ["first", "second"] &&
                engine.hasPendingPrefetch &&
                engine.prefetchedTexts.contains("third")
        }
        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        // Same prefetchIdentifier ⇒ engine reuses prepared audio, no resynth.
        XCTAssertEqual(engine.spokenIdentifiers[1], secondPrefetchIdentifier)
        // Third still pending; full-waterline await would not have reached here.
        XCTAssertFalse(engine.spokenTexts.contains("third"))
        synthesizer.stop()
    }

    func testAutomaticContinuationFallsBackToLiveWhenPrefetchFails() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }
        XCTAssertEqual(engine.spokenTexts, ["first"])

        // Pending look-ahead fails → waiter wakes and live-speaks second.
        engine.completePrefetch(returning: nil)
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        synthesizer.stop()
    }

    func testStopDuringForwardPrefetchWaitDoesNotDeadlock() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }
        XCTAssertEqual(engine.spokenTexts, ["first"])

        synthesizer.stop()
        XCTAssertEqual(synthesizer.state, .stopped)
        // Invalidate wakes the waiter; cancel completes the pending engine work.
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
    }

    func testPauseDuringForwardPrefetchWaitDoesNotDeadlock() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }

        synthesizer.pause()
        guard case .paused = synthesizer.state else {
            return XCTFail("Expected paused state after pause during wait")
        }
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        synthesizer.stop()
    }

    func testNextDuringForwardPrefetchWaitDoesNotDeadlock() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }
        XCTAssertEqual(engine.spokenTexts, ["first"])

        synthesizer.next()
        // From first, next must land on second — not skip to third.
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testConfigChangeDuringForwardPrefetchWaitSerializesIterator() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("third", href: "third.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && iterator.hasSuspendedNext
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }

        // Config invalidates look-ahead without bumping operationGeneration; the
        // play task must wait for the cancelled iterator call to exit before
        // live-loading the next utterance.
        synthesizer.config.defaultLanguage = Language("fr")
        try await waitUntil { engine.cancelPrefetchCount >= 1 || !iterator.hasSuspendedNext }

        iterator.openGate()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testInitialPrefetchReturnsAfterFirstUtteranceAndFillsForwardInBackground() async throws {
        let first = textElement("first", href: "first.xhtml")
        let second = textElement("second", href: "second.xhtml")
        let third = textElement("third", href: "third.xhtml")
        let fourth = textElement("fourth", href: "fourth.xhtml")
        // cancelsPendingPrefetch: hard-timeout path can unblock a hung waterline wait.
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 2,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [first, second, third, fourth],
            engine: engine
        )

        // Hard timeout: if we regress to "await full waterline", fail within 1s
        // instead of hanging on the deferred second continuation.
        let didPrefetch = try await withHardTimeout(1, onTimeout: {
            engine.cancelPrefetch()
        }) {
            await synthesizer.prefetch()
        }
        XCTAssertTrue(didPrefetch)
        XCTAssertEqual(engine.prefetchedTexts.first, "first")
        // Full waterline must not be a precondition of returning.
        XCTAssertFalse(engine.prefetchedTexts.contains("fourth"))

        try await waitUntil {
            engine.prefetchedTexts.contains("second") && engine.hasPendingPrefetch
        }
        engine.completePrefetch()
        try await waitUntil {
            engine.prefetchedTexts == ["first", "second", "third", "fourth"]
        }

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testConfigChangeDuringFirstUtteranceSerializesBeforePlayNext() async throws {
        // Cancelled `next` does not exit until `openCleanupGate`, stably holding
        // the window: forward task slot cleared, but old iterator.next still active.
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("third", href: "third.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2,
            delaysCancellationExit: true
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && iterator.hasSuspendedNext
        }

        // Mid-utterance config invalidates look-ahead.
        synthesizer.config.defaultLanguage = Language("fr")
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        try await waitUntil { iterator.hasSuspendedCleanup }

        // End first utterance. Correct code awaits cancellation drain and must
        // NOT enter a new next() while cleanup is still held.
        engine.completeSpeech()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(engine.spokenTexts, ["first"])
        XCTAssertEqual(iterator.nextCallCount, 2)
        XCTAssertEqual(iterator.activeCallCount, 1)
        XCTAssertFalse(engine.spokenTexts.contains("second"))

        iterator.openCleanupGate()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testReleasingSynthesizerDuringForwardEnginePrefetchCancelsWork() async throws {
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 2,
            cancelsPendingPrefetch: true
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )
        weak let weakSynthesizer = synthesizer

        let didPrefetch = try await withHardTimeout(1, onTimeout: {
            engine.cancelPrefetch()
        }) {
            await synthesizer!.prefetch()
        }
        XCTAssertTrue(didPrefetch)
        try await waitUntil {
            engine.prefetchedTexts.contains("second") && engine.hasPendingPrefetch
        }

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        try await waitUntil { engine.cancelPrefetchCount >= 1 }
        XCTAssertFalse(engine.hasPendingPrefetch)
    }

    func testReleasingSynthesizerDuringForwardIteratorLoadCancelsWork() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: PrefetchingTTSEngine()
        )
        weak let weakSynthesizer = synthesizer

        // First content loads (call 1); forward look-ahead suspends on call 2.
        let didPrefetch = try await withHardTimeout(1, onTimeout: {
            iterator.openGate()
        }) {
            await synthesizer!.prefetch()
        }
        XCTAssertTrue(didPrefetch)
        try await waitUntil { iterator.hasSuspendedNext }

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        // Cancelled look-ahead must resume the gated iterator so it can exit.
        try await waitUntil { !iterator.hasSuspendedNext }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
    }

    func testReleasingSynthesizerWhileLaterForwardPrefetchIsPending() async throws {
        // Second look-ahead succeeds; hang on third engine.prefetch.
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 3,
            cancelsPendingPrefetch: true
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine
        )
        weak let weakSynthesizer = synthesizer

        let didPrefetch = try await withHardTimeout(1, onTimeout: {
            engine.cancelPrefetch()
        }) {
            await synthesizer!.prefetch()
        }
        XCTAssertTrue(didPrefetch)
        // first (initial) + second (forward) immediate; third deferred.
        try await waitUntil {
            engine.prefetchedTexts == ["first", "second", "third"] &&
                engine.hasPendingPrefetch
        }

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        try await waitUntil { engine.cancelPrefetchCount >= 1 }
        XCTAssertFalse(engine.hasPendingPrefetch)
    }

    func testReleasingSynthesizerAfterEmptyContentWhileIteratorIsSuspended() async throws {
        // Forward skips empty (no utterances), then hangs on the next next().
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("", href: "empty.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 3
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: PrefetchingTTSEngine()
        )
        weak let weakSynthesizer = synthesizer

        let didPrefetch = try await withHardTimeout(1, onTimeout: {
            iterator.openGate()
        }) {
            await synthesizer!.prefetch()
        }
        XCTAssertTrue(didPrefetch)
        try await waitUntil { iterator.hasSuspendedNext }
        XCTAssertEqual(iterator.nextCallCount, 3)

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        try await waitUntil { !iterator.hasSuspendedNext }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
    }

    func testTokenizeReentryDoesNotCommitStaleForwardUtterances() async throws {
        final class ReentrantTokenizer: @unchecked Sendable {
            var onTokenize: ((Language?, Int) -> Void)?
            private var count = 0

            func makeTokenizer(language: Language?) -> ContentTokenizer {
                { [self] element in
                    try self.tokenize(element, language: language)
                }
            }

            private func tokenize(_ element: ContentElement, language: Language?) throws -> [ContentElement] {
                count += 1
                onTokenize?(language, count)
                guard var textElement = element as? TextContentElement else {
                    return [element]
                }
                // Observable config effect: French default language prefixes text.
                if language?.code.bcp47.lowercased().hasPrefix("fr") == true {
                    textElement.segments = textElement.segments.map { segment in
                        var segment = segment
                        if !segment.text.hasPrefix("fr ") {
                            segment.text = "fr " + segment.text
                        }
                        return segment
                    }
                }
                return [textElement]
            }
        }

        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine,
            tokenizerFactory: { language in tokenizer.makeTokenizer(language: language) }
        )
        tokenizer.onTokenize = { [weak synthesizer] _, count in
            // Second tokenize is the forward look-ahead of "second". Invalidate
            // under the in-flight call so a stale EN result must not be committed.
            if count == 2 {
                synthesizer?.config.defaultLanguage = Language("fr")
            }
        }

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        engine.completeSpeech()
        // Live path after discard must re-tokenize under fr → "fr second".
        // Committing the stale EN "second" would fail this assertion.
        try await waitUntil { engine.spokenTexts == ["first", "fr second"] }
        synthesizer.stop()
    }

    func testCancellingSuspendedInitialPrefetchCancelsEngine() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let prefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil { engine.hasPendingPrefetch }
        prefetchTask.cancel()

        let didPrefetch = await prefetchTask.value
        XCTAssertFalse(didPrefetch)
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        synthesizer.stop()
    }

    func testLateCancellationDoesNotInvalidateNewStart() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let oldPrefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil { engine.hasPendingPrefetch }
        oldPrefetchTask.cancel()
        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        _ = await oldPrefetchTask.value
        synthesizer.stop()
    }

    func testCancelledPrefetchDoesNotAdvanceNewStartIterator() async throws {
        let elements = [textElement("first"), textElement("second")]
        let oldIterator = GatedArrayContentIterator(
            elements: elements,
            startIndex: 0,
            gatedNextCall: 1
        )
        let newIterator = ArrayContentIterator(elements: elements, startIndex: 0)
        let iteratorFactory = IteratorFactory([oldIterator, newIterator])
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: iteratorFactory.make),
            engine: engine
        )
        defer { oldIterator.openGate() }

        let prefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil { oldIterator.hasSuspendedNext }
        prefetchTask.cancel()
        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        oldIterator.openGate()
        let didPrefetch = await prefetchTask.value
        XCTAssertFalse(didPrefetch)
        XCTAssertEqual(engine.spokenTexts, ["first"])
        synthesizer.stop()
    }

    func testStartCancelsOldForwardPrefetchBeforeUsingNewIterator() async throws {
        let elements = [textElement("first"), textElement("second")]
        let oldIterator = GatedArrayContentIterator(
            elements: elements,
            startIndex: 0,
            gatedNextCall: 2
        )
        let newIterator = ArrayContentIterator(elements: elements, startIndex: 0)
        let iteratorFactory = IteratorFactory([oldIterator, newIterator])
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: iteratorFactory.make),
            engine: engine
        )
        defer { oldIterator.openGate() }

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && oldIterator.hasSuspendedNext
        }
        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first", "first"] }
        XCTAssertFalse(oldIterator.hasSuspendedNext)
        synthesizer.next()
        try await waitUntil { engine.spokenTexts == ["first", "first", "second"] }

        synthesizer.stop()
    }

    func testNavigationSerializesCancelledCurrentIteratorOperation() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [textElement("first"), textElement("second")],
            startIndex: 0,
            gatedNextCall: 2
        )
        let engine = SpeechEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        synthesizer.next()
        try await waitUntil { iterator.hasSuspendedNext }
        synthesizer.next()

        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testNavigationPreservesElementReturnedAfterCancellation() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [textElement("first"), textElement("second"), textElement("third")],
            startIndex: 0,
            gatedNextCall: 2,
            returnsElementOnCancellation: true
        )
        let engine = SpeechEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        synthesizer.next()
        try await waitUntil { iterator.hasSuspendedNext }
        synthesizer.next()

        try await waitUntil { engine.spokenTexts.count == 2 }
        XCTAssertEqual(engine.spokenTexts, ["first", "second"])
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testRepeatedDirectionChangesKeepPendingIteratorInSync() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [textElement("first"), textElement("second"), textElement("third")],
            startIndex: 0,
            gatedNextCall: 2,
            gatedPreviousCall: 1,
            returnsElementOnCancellation: true
        )
        let engine = SpeechEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        synthesizer.next()
        try await waitUntil { iterator.hasSuspendedNext }
        synthesizer.previous()
        try await waitUntil { iterator.hasSuspendedPrevious }
        synthesizer.next()

        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testNavigationWaitsForCancelledSpeechBeforeStartingNext() async throws {
        let engine = SpeechEngine(completesOnCancellation: false)
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        synthesizer.next()
        await Task.yield()

        XCTAssertEqual(engine.spokenTexts, ["first"])
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(engine.maximumConcurrentSpeeches, 1)
        synthesizer.stop()
        engine.completeSpeech()
    }

    func testCancellingPreparedPrefetchDoesNotInvalidatePlaybackCache() async throws {
        // `prefetch` returns after the first utterance; forward waterline continues
        // on a background/unstructured task (MainActor-inherited, not detached).
        // Cancelling the completed caller Task must not wipe prepared audio that
        // `start` is about to consume.
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 2,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        let prefetchTask = Task { await synthesizer.prefetch() }
        let didPrefetch = await prefetchTask.value
        XCTAssertTrue(didPrefetch)

        try await waitUntil {
            engine.prefetchedTexts == ["first", "second"] && engine.hasPendingPrefetch
        }
        prefetchTask.cancel()
        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        engine.completePrefetch()
        synthesizer.stop()
    }

    func testStartDuringInitialForwardPrefetchUsesOneTask() async throws {
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 2,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        let prefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil {
            engine.prefetchedTexts == ["first", "second"] && engine.hasPendingPrefetch
        }
        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        XCTAssertEqual(engine.maximumConcurrentPrefetches, 1)
        synthesizer.stop()
        _ = await prefetchTask.value
    }

    func testInitialPrefetchRetainsNextUtteranceLongerThanWaterline() async throws {
        let engine = PrefetchingTTSEngine(
            prefetchDurations: ["first": 5, "second": 22],
            rejectsDurationExceedingMaximum: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine
        )

        let didPrefetch = await synthesizer.prefetch()
        XCTAssertTrue(didPrefetch)
        // Forward look-ahead continues after return; wait for the retained second.
        try await waitUntil { engine.prefetchedTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testForwardPrefetchRejectsDurationExceedingMaximum() async throws {
        let engine = PrefetchingTTSEngine(
            deferPrefetchOnCall: 2,
            prefetchDurations: ["second": 100],
            clampsPrefetchDuration: false,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second"), textElement("third")],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.prefetchedTexts == ["second"] }
        engine.completeSpeech()
        // Rejected look-ahead ends the forward task without invalidate; second is
        // spoken live, then a new forward task prefetches third (deferred).
        try await waitUntil {
            engine.spokenTexts == ["first", "second"] &&
                engine.prefetchedTexts == ["second", "third"] &&
                engine.hasPendingPrefetch
        }

        synthesizer.stop()
        // Only stop cancels the in-flight third (no cancel on the rejected second).
        try await waitUntil { engine.cancelPrefetchCount == 1 }
    }

    func testPreviousRollsBackUnconsumedPrefetch() async throws {
        let first = textElement("first", href: "first.xhtml")
        let second = textElement("second", href: "second.xhtml")
        let third = textElement("third", href: "third.xhtml")
        let empty = textElement("", href: "empty.xhtml")
        let fourth = textElement("fourth", href: "fourth.xhtml")
        let fifth = textElement("fifth", href: "fifth.xhtml")
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [first, second, third, empty, fourth, fifth],
            startIndex: 1,
            engine: engine
        )

        synthesizer.start(from: second.locator)
        try await waitUntil {
            engine.spokenTexts == ["second"] &&
                engine.prefetchedTexts.first == "third"
        }

        synthesizer.previous()

        try await waitUntil { engine.spokenTexts == ["second", "first"] }
        XCTAssertGreaterThanOrEqual(engine.cancelPrefetchCount, 1)
        synthesizer.stop()
    }

    func testAutomaticContinuationWaitsForSuspendedPrefetchIteratorAdvance() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("third", href: "third.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                iterator.hasSuspendedNext
        }
        engine.completeSpeech()
        try await waitUntil { synthesizer.isWaitingForForwardPrefetchForTesting }

        // Continuation waits for the in-flight look-ahead iterator instead of
        // cancelling it; second must not speak until the gate opens.
        XCTAssertEqual(engine.spokenTexts, ["first"])
        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        XCTAssertTrue(iterator.hasSuspendedNext)

        iterator.openGate()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        XCTAssertEqual(engine.cancelPrefetchCount, 0)
        try await waitUntil { engine.prefetchedTexts.contains("third") }
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second", "third"] }
        synthesizer.stop()
    }

    func testPreviousCancelsSuspendedPrefetchAndRollsBackEmptyElement() async throws {
        let first = textElement("first", href: "first.xhtml")
        let second = textElement("second", href: "second.xhtml")
        let iterator = GatedArrayContentIterator(
            elements: [
                first,
                second,
                textElement("", href: "empty.xhtml"),
                textElement("third", href: "third.xhtml"),
            ],
            startIndex: 1,
            gatedNextCall: 2
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start(from: second.locator)
        try await waitUntil {
            engine.spokenTexts == ["second"] &&
                iterator.hasSuspendedNext
        }
        synthesizer.previous()

        try await waitUntil { engine.spokenTexts == ["second", "first"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        synthesizer.stop()
    }

    func testPreviousRollsBackTrailingAdvanceAfterPrefetchIteratorError() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("", href: "empty.xhtml"),
            ],
            startIndex: 1,
            gatedNextCall: 99,
            throwingNextCall: 4
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { iterator.nextCallCount == 3 }
        synthesizer.pause()
        synthesizer.resume()
        try await waitUntil {
            engine.spokenTexts == ["second", "second"] &&
                iterator.nextCallCount == 4
        }
        synthesizer.previous()

        try await waitUntil { engine.spokenTexts == ["second", "second", "first"] }
        synthesizer.stop()
    }

    func testNextCompletesCancelledForwardBufferRollback() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("third", href: "third.xhtml"),
                textElement("fourth", href: "fourth.xhtml"),
            ],
            startIndex: 1,
            gatedNextCall: 99,
            gatedPreviousCall: 2
        )
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["second"] && iterator.nextCallCount >= 3
        }
        synthesizer.previous()
        try await waitUntil { iterator.hasSuspendedPrevious }
        synthesizer.next()

        try await waitUntil { engine.spokenTexts == ["second", "third"] }
        try await waitUntil { engine.prefetchedTexts.contains("fourth") }
        let previousCallCount = iterator.previousCallCount
        synthesizer.next()
        try await waitUntil { engine.spokenTexts == ["second", "third", "fourth"] }
        XCTAssertEqual(iterator.previousCallCount, previousCallCount)
        synthesizer.previous()
        try await waitUntil { engine.spokenTexts == ["second", "third", "fourth", "third"] }
        synthesizer.stop()
    }

    func testCancellingRetokenizedForwardGroupKeepsItForNextOperation() async throws {
        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second"), textElement("third")],
            engine: engine,
            tokenizerFactory: { _ in tokenizer.tokenize }
        )
        tokenizer.onSecondTokenization = { synthesizer.next() }

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.prefetchedTexts.contains("second")
        }
        synthesizer.config.defaultLanguage = Language("fr")
        tokenizer.cancelOnSecondTokenization = true
        engine.completeSpeech()

        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testCancellingAfterEmptyRetokenizedGroupRewindsAllBufferedContent() async throws {
        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"), textElement("second"),
                textElement("third"), textElement("fourth"),
            ],
            engine: engine,
            tokenizerFactory: { _ in tokenizer.tokenize }
        )
        tokenizer.onThirdTokenization = { synthesizer.previous() }

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.prefetchedTexts.contains("fourth")
        }
        synthesizer.config.defaultLanguage = Language("fr")
        tokenizer.makeSecondEmpty = true
        tokenizer.cancelOnThirdTokenization = true
        engine.completeSpeech()

        try await waitUntil {
            synthesizer.state == .stopped || engine.spokenTexts.count > 1
        }
        XCTAssertEqual(synthesizer.state, .stopped)
        XCTAssertEqual(engine.spokenTexts, ["first"])
    }

    func testLiveCommitClearsTrailingAdvanceFromEmptyLastBufferedGroup() async throws {
        var third = textElement("third")
        third.segments = [
            .init(locator: third.locator, text: "third first"),
            .init(locator: third.locator, text: "third second"),
        ]
        let iterator = GatedArrayContentIterator(
            elements: [textElement("first"), textElement("second"), third],
            startIndex: 0,
            gatedNextCall: 99
        )
        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine(prefetchDurations: ["second": 15])
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine,
            tokenizerFactory: { _ in tokenizer.tokenize }
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.prefetchedTexts == ["second"]
        }
        synthesizer.config.defaultLanguage = Language("fr")
        tokenizer.makeSecondEmpty = true
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "third first"] }
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "third first", "third second"] }

        synthesizer.previous()
        try await waitUntil { engine.spokenTexts == ["first", "third first", "third second", "third first"] }
        XCTAssertEqual(iterator.previousCallCount, 0)
        synthesizer.stop()
    }

    func testStopInvalidatesLatePrefetch() async throws {
        let engine = PrefetchingTTSEngine(defersPrefetch: true)
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.hasPendingPrefetch }

        synthesizer.stop()
        engine.completePrefetch()
        await Task.yield()

        XCTAssertEqual(
            synthesizer.state,
            PublicationSpeechSynthesizer.State.stopped
        )
        XCTAssertEqual(engine.spokenTexts, ["first"])
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
    }

    func testFailedInitialPrefetchIsNotMarkedPrepared() async throws {
        let engine = PrefetchingTTSEngine(prefetchResult: nil)
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first", href: "first.xhtml")],
            engine: engine
        )

        let didPrefetch = await synthesizer.prefetch()
        XCTAssertFalse(didPrefetch)
        synthesizer.start()
        try await waitUntil { engine.spokenIdentifiers.count == 1 }

        XCTAssertEqual(engine.prefetchedIdentifiers.count, 1)
        XCTAssertNotEqual(
            engine.spokenIdentifiers[0],
            engine.prefetchedIdentifiers[0]
        )
        synthesizer.stop()
    }

    func testInitialPrefetchRejectsNonfiniteDuration() async throws {
        let engine = PrefetchingTTSEngine(
            prefetchResult: .infinity,
            clampsPrefetchDuration: false
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let didPrefetch = await synthesizer.prefetch()

        XCTAssertFalse(didPrefetch)
        synthesizer.stop()
    }

    func testInitialPrefetchRejectsDurationExceedingMaximum() async throws {
        let engine = PrefetchingTTSEngine(
            prefetchResult: 100,
            clampsPrefetchDuration: false
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let didPrefetch = await synthesizer.prefetch()

        XCTAssertFalse(didPrefetch)
        synthesizer.stop()
    }

    func testPauseInvalidatesLatePrefetch() async throws {
        let engine = PrefetchingTTSEngine(defersPrefetch: true)
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.hasPendingPrefetch }

        synthesizer.pause()
        engine.completePrefetch()
        await Task.yield()

        guard case let .paused(utterance) = synthesizer.state else {
            return XCTFail("Expected the paused first utterance")
        }
        XCTAssertEqual(utterance.text, "first")
        XCTAssertEqual(engine.spokenTexts, ["first"])
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        synthesizer.stop()
    }

    func testNextInvalidatesLatePrefetch() async throws {
        let engine = PrefetchingTTSEngine(defersPrefetch: true)
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.hasPendingPrefetch }

        synthesizer.next()
        engine.completePrefetch()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }

        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        XCTAssertEqual(engine.spokenTexts, ["first", "second"])
        synthesizer.stop()
    }

    func testPrefetchDoesNotInterruptPlayback() async throws {
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        let didPrefetch = await synthesizer.prefetch()
        XCTAssertFalse(didPrefetch)
        XCTAssertEqual(engine.spokenTexts, ["first"])
        guard case let .playing(utterance, range: _) = synthesizer.state else {
            return XCTFail("Expected playback to continue")
        }
        XCTAssertEqual(utterance.text, "first")
        synthesizer.stop()
    }

    func testDelegateReceivesStateTransitionsInOrder() async throws {
        let delegate = RecordingSpeechSynthesizerDelegate()
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )
        synthesizer.delegate = delegate

        synthesizer.start()
        try await waitUntil {
            if case .playing = synthesizer.state {
                return true
            }
            return false
        }
        synthesizer.pause()
        try await waitUntil {
            if case .paused = delegate.states.last {
                return true
            }
            return false
        }

        guard case .playing = delegate.states[0] else {
            return XCTFail("Expected the initial playing state")
        }
        guard case .paused = delegate.states.last else {
            return XCTFail("Expected the paused state")
        }
        synthesizer.stop()
    }

    func testDelegateCanStopBeforeEngineStarts() async throws {
        let delegate = RecordingSpeechSynthesizerDelegate()
        let engine = PrefetchingTTSEngine()
        var synthesizer: PublicationSpeechSynthesizer!
        delegate.onStateChange = { state in
            if case .playing = state {
                synthesizer.stop()
            }
        }
        synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )
        synthesizer.delegate = delegate

        synthesizer.start()
        try await waitUntil { delegate.states.count == 2 && synthesizer.state == .stopped }
        await Task.yield()

        XCTAssertEqual(engine.spokenTexts, [])
    }

    func testDelegateStopFromStoppedNotificationDoesNotRecurse() async throws {
        let delegate = RecordingSpeechSynthesizerDelegate()
        let engine = PrefetchingTTSEngine()
        var synthesizer: PublicationSpeechSynthesizer!
        delegate.onStateChange = { state in
            if case .stopped = state {
                synthesizer.stop()
            }
        }
        synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )
        synthesizer.delegate = delegate

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        synthesizer.stop()

        XCTAssertEqual(delegate.states.filter { $0 == .stopped }.count, 1)
    }

    func testDelegateConfigurationChangeAppliesToNextUtterance() async throws {
        let english = Language("en")
        let french = Language("fr")
        let delegate = RecordingSpeechSynthesizerDelegate()
        let engine = PrefetchingTTSEngine()
        var synthesizer: PublicationSpeechSynthesizer!
        delegate.onStateChange = { state in
            if case .playing = state {
                synthesizer.config.defaultLanguage = french
            }
        }
        synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )
        synthesizer.config.defaultLanguage = english
        synthesizer.delegate = delegate

        synthesizer.start()
        try await waitUntil { engine.spokenVoiceOrLanguages.count == 1 }

        guard case let .right(language) = engine.spokenVoiceOrLanguages[0] else {
            return XCTFail("Expected language fallback")
        }
        XCTAssertEqual(language, english)
        engine.completeSpeech()
        try await waitUntil { engine.spokenVoiceOrLanguages.count == 2 }
        guard case let .right(nextLanguage) = engine.spokenVoiceOrLanguages[1] else {
            return XCTFail("Expected language fallback")
        }
        XCTAssertEqual(nextLanguage, french)
        synthesizer.stop()
    }

    func testConfigChangeInvalidatesPrefetchedAudio() async throws {
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let didPrefetch = await synthesizer.prefetch()
        XCTAssertTrue(didPrefetch)
        synthesizer.config.defaultLanguage = Language("fr")

        try await waitUntil { engine.cancelPrefetchCount == 1 }
        XCTAssertEqual(engine.cancelPrefetchCount, 1)
        synthesizer.stop()
    }

    func testConfigChangeInvalidatesInFlightInitialPrefetch() async throws {
        let engine = PrefetchingTTSEngine(defersPrefetch: true)
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first")],
            engine: engine
        )

        let prefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil { engine.hasPendingPrefetch }
        synthesizer.config.defaultLanguage = Language("fr")
        engine.completePrefetch()

        let didPrefetch = await prefetchTask.value
        XCTAssertFalse(didPrefetch)
        synthesizer.stop()
    }

    func testCancelledInitialPrefetchIsNotMarkedPrepared() async throws {
        // Defer the *first* utterance so cancellation still races the initial
        // prepare path (forward waterline no longer blocks `prefetch` return).
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )

        let prefetchTask = Task { await synthesizer.prefetch() }
        try await waitUntil { engine.hasPendingPrefetch }
        prefetchTask.cancel()

        let didPrefetch = await prefetchTask.value
        XCTAssertFalse(didPrefetch)
        synthesizer.start()
        try await waitUntil { engine.spokenIdentifiers.count == 1 }
        // Cancelled prepare must not leave a reusable prepared utterance.
        if !engine.prefetchedIdentifiers.isEmpty {
            XCTAssertNotEqual(engine.spokenIdentifiers[0], engine.prefetchedIdentifiers[0])
        }
        synthesizer.stop()
    }

    func testNonpositivePrefetchDurationStopsPrefetching() async throws {
        let engine = PrefetchingTTSEngine(prefetchDurations: ["second": 0])
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.prefetchedTexts.contains("second") }
        await Task.yield()

        XCTAssertEqual(engine.prefetchedTexts, ["second"])
        synthesizer.stop()
    }

    func testConfigChangeRetokenizesPrefetchedContent() async throws {
        let french = Language("fr")
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine,
            tokenizerFactory: { language in { content in
                guard
                    language == french,
                    var content = content as? TextContentElement
                else {
                    return [content]
                }
                content.segments = content.segments.map { segment in
                    var segment = segment
                    segment.text = "fr " + segment.text
                    return segment
                }
                return [content]
            } }
        )

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                engine.prefetchedTexts.contains("second")
        }
        synthesizer.config.defaultLanguage = french
        engine.completeSpeech()

        try await waitUntil { engine.spokenTexts == ["first", "fr second"] }
        synthesizer.stop()
    }

    func testConfigChangeRetokenizesBufferedGroupsInOrderWithoutSkipping() async throws {
        let french = Language("fr")
        let engine = PrefetchingTTSEngine(prefetchResult: 5)
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
                textElement("fourth"),
            ],
            engine: engine,
            tokenizerFactory: { language in { content in
                guard
                    language == french,
                    var content = content as? TextContentElement
                else {
                    return [content]
                }
                content.segments = content.segments.map { segment in
                    var segment = segment
                    segment.text = "fr " + segment.text
                    return segment
                }
                return [content]
            } }
        )

        synthesizer.start()
        // Waterline should cover second+third (+maybe fourth) before config change.
        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                engine.prefetchedTexts.contains("second") &&
                engine.prefetchedTexts.contains("third")
        }
        synthesizer.config.defaultLanguage = french
        engine.completeSpeech()

        // Live play of retokenized second, then look-ahead must re-prefetch
        // fr third (not skip to fr fourth) while second is still speaking.
        try await waitUntil { engine.spokenTexts == ["first", "fr second"] }
        try await waitUntil {
            engine.prefetchedTexts.contains("fr third") &&
                !engine.spokenTexts.contains("fr third")
        }
        let thirdPrefetchIndex = try XCTUnwrap(
            engine.prefetchedTexts.firstIndex(of: "fr third")
        )
        if let fourthIndex = engine.prefetchedTexts.firstIndex(of: "fr fourth") {
            XCTAssertLessThan(thirdPrefetchIndex, fourthIndex)
        }
        let thirdPrefetchIdentifier = engine.prefetchedIdentifiers[thirdPrefetchIndex]

        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "fr second", "fr third"] }
        // Same identifier proves look-ahead audio was reused (not live resynth only).
        XCTAssertEqual(engine.spokenIdentifiers[2], thirdPrefetchIdentifier)
        XCTAssertFalse(engine.spokenTexts.contains("fourth"))
        XCTAssertFalse(engine.spokenTexts.contains("fr fourth"))
        synthesizer.stop()
    }

    func testBufferedGroupRetokenizeReentryConfigDoesNotCommitStaleResult() async throws {
        let french = Language("fr")
        let german = Language("de")
        final class ReentrantTokenizer: @unchecked Sendable {
            var onCollectRetokenize: (() -> Void)?
            private var frenchTokenizeCount = 0

            func makeTokenizer(language: Language?) -> ContentTokenizer {
                { [self] element in
                    guard var text = element as? TextContentElement else {
                        return [element]
                    }
                    let code = language?.code.bcp47.lowercased() ?? ""
                    if code.hasPrefix("fr") {
                        frenchTokenizeCount += 1
                        // Second French tokenize is collectForwardPrefetchCandidates
                        // retokenizing the remaining invalidated "third" group while
                        // "fr second" is already playing — not the live second consume.
                        if frenchTokenizeCount == 2 {
                            onCollectRetokenize?()
                        }
                        text.segments = text.segments.map { segment in
                            var segment = segment
                            segment.text = "fr " + segment.text
                            return segment
                        }
                    } else if code.hasPrefix("de") {
                        text.segments = text.segments.map { segment in
                            var segment = segment
                            segment.text = "de " + segment.text
                            return segment
                        }
                    }
                    return [text]
                }
            }
        }

        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine(prefetchResult: 5)
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine,
            tokenizerFactory: { language in tokenizer.makeTokenizer(language: language) }
        )
        tokenizer.onCollectRetokenize = { [weak synthesizer] in
            // Mid-collect reentry: final config is German — stale "fr third" must not win.
            synthesizer?.config.defaultLanguage = german
        }

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                engine.prefetchedTexts.contains("second") &&
                engine.prefetchedTexts.contains("third")
        }
        // Invalidate buffered groups; live path consumes second under French
        // (frenchTokenizeCount == 1). While second speaks, collect retokenizes
        // remaining "third" (count == 2) and re-enters to German.
        synthesizer.config.defaultLanguage = french
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "fr second"] }

        // Stale "fr third" from the interrupted collect must not be committed;
        // after second ends, live load uses German.
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "fr second", "de third"] }
        XCTAssertFalse(engine.spokenTexts.contains("fr third"))
        XCTAssertFalse(engine.prefetchedTexts.contains("fr third"))
        synthesizer.stop()
    }

    func testEmptyBufferedGroupDoesNotRetainAcrossSubsequentIteratorHang() async throws {
        // Fill the entire forward waterline with "vanish" (15s) so forward stops
        // without hanging on a later next(). Live load after empty drain is the
        // gated call that must not pin self.
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("vanish", href: "vanish.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            startIndex: 0,
            // call 1: first (play), call 2: vanish (forward waterline), call 3: live second
            gatedNextCall: 3,
            delaysCancellationExit: true
        )
        let french = Language("fr")
        var vanishRetokenizedEmpty = false
        let engine = PrefetchingTTSEngine(
            prefetchDurations: ["vanish": 15],
            clampsPrefetchDuration: true
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine,
            tokenizerFactory: { language in
                { content in
                    guard var text = content as? TextContentElement else {
                        return [content]
                    }
                    let raw = text.segments.map(\.text).joined()
                    if language?.code.bcp47.lowercased().hasPrefix("fr") == true {
                        if raw == "vanish" {
                            vanishRetokenizedEmpty = true
                            return [] // empty after config retokenize
                        }
                        text.segments = text.segments.map { segment in
                            var segment = segment
                            segment.text = "fr " + segment.text
                            return segment
                        }
                    }
                    return [text]
                }
            }
        )
        weak let weakSynthesizer = synthesizer

        synthesizer?.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] &&
                engine.prefetchedTexts.contains("vanish") &&
                // Forward waterline full — must not still be suspended on call 3.
                !iterator.hasSuspendedNext
        }
        XCTAssertEqual(iterator.nextCallCount, 2)

        synthesizer?.config.defaultLanguage = french
        engine.completeSpeech()
        // Live path: empty vanish group drained, then hang on live second (call 3).
        try await waitUntil {
            vanishRetokenizedEmpty && iterator.hasSuspendedNext && iterator.nextCallCount == 3
        }
        XCTAssertFalse(iterator.hasSuspendedCleanup)

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        try await waitUntil {
            if iterator.hasSuspendedCleanup {
                iterator.openCleanupGate()
            }
            return iterator.activeCallCount == 0
        }
    }

    func testConfigTokenizeRetryDoesNotSpinForever() async throws {
        final class FlipFlopTokenizer: @unchecked Sendable {
            weak var synthesizer: PublicationSpeechSynthesizer?
            var calls = 0

            func makeTokenizer(language: Language?) -> ContentTokenizer {
                { [self] element in
                    calls += 1
                    let raw = (element as? TextContentElement)?.segments.map(\.text).joined() ?? ""
                    // Only flip on "second" so first can start; unbounded flip would
                    // livelock MainActor without a retry cap.
                    if raw == "second" {
                        if language?.code.bcp47.lowercased().hasPrefix("fr") == true {
                            synthesizer?.config.defaultLanguage = Language("en")
                        } else {
                            synthesizer?.config.defaultLanguage = Language("fr")
                        }
                    }
                    return [element]
                }
            }
        }

        let tokenizer = FlipFlopTokenizer()
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine,
            tokenizerFactory: { language in tokenizer.makeTokenizer(language: language) }
        )
        tokenizer.synthesizer = synthesizer

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        let callsAfterFirst = tokenizer.calls
        engine.completeSpeech()
        // Must return to a stable state without hanging the MainActor.
        try await waitUntil(timeout: 2) {
            synthesizer.state == .stopped || engine.spokenTexts.count >= 2
        }
        // Bounded retries: far fewer than an unbounded spin.
        XCTAssertLessThan(tokenizer.calls - callsAfterFirst, 40)
        synthesizer.stop()
    }

    func testStartTextTrimSurvivesConfigReentryDuringTokenize() async throws {
        final class ReentrantTokenizer: @unchecked Sendable {
            weak var synthesizer: PublicationSpeechSynthesizer?
            private var didFlip = false

            func makeTokenizer(language: Language?) -> ContentTokenizer {
                { [self] element in
                    if !didFlip {
                        didFlip = true
                        synthesizer?.config.defaultLanguage = Language("fr")
                    }
                    return [element]
                }
            }
        }

        let full = "prefix kept body"
        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine()
        let start = locator(text: .init(before: "prefix ", highlight: "kept body"))
        let element = TextContentElement(
            locator: start,
            role: .body,
            segments: [.init(locator: start, text: full)]
        )
        let synthesizer = try makeSynthesizer(
            elements: [element],
            engine: engine,
            tokenizerFactory: { language in tokenizer.makeTokenizer(language: language) }
        )
        tokenizer.synthesizer = synthesizer

        synthesizer.start(from: start)
        try await waitUntil { engine.spokenTexts.count == 1 }
        // Trim must still apply after config reentry discarded the first tokenize.
        XCTAssertEqual(engine.spokenTexts[0], "kept body")
        synthesizer.stop()
    }

    func testPendingOppositeUndoAccountsForCancelThatStillReturnsElement() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "a.xhtml"),
                textElement("second", href: "b.xhtml"),
                textElement("third", href: "c.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2,
            gatedPreviousCall: 1,
            returnsElementOnCancellation: true
        )
        let engine = SpeechEngine()
        let synthesizer = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )

        synthesizer.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        // Cancel first speech is implicit when navigating; still one spoken so far.
        XCTAssertEqual(engine.spokenTexts, ["first"])

        synthesizer.next()
        try await waitUntil { iterator.hasSuspendedNext }
        XCTAssertEqual(iterator.nextCallCount, 2)

        // Cancelled next still returns second (returnsElementOnCancellation) and
        // must leave pending accounting consistent for the opposite undo.
        synthesizer.previous()
        try await waitUntil { iterator.hasSuspendedPrevious }
        XCTAssertEqual(iterator.previousCallCount, 1)
        // Must not already be speaking second before opposite/next completes.
        XCTAssertEqual(engine.spokenTexts, ["first"])

        synthesizer.next()
        // After pending-preserving cancel + opposite accounting, next must land
        // on second exactly once — never skip to third via double undo.
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        XCTAssertEqual(iterator.maximumConcurrentCalls, 1)
        XCTAssertEqual(engine.spokenTexts.filter { $0 == "second" }.count, 1)
        XCTAssertFalse(engine.spokenTexts.contains("third"))

        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second", "third"] }
        synthesizer.stop()
    }

    func testBufferedGroupRetokenizeReentryStopDoesNotCrash() async throws {
        final class ReentrantTokenizer: @unchecked Sendable {
            weak var synthesizer: PublicationSpeechSynthesizer?
            private var didStop = false

            func makeTokenizer(language: Language?) -> ContentTokenizer {
                { [self] element in
                    if
                        language?.code.bcp47.lowercased().hasPrefix("fr") == true,
                        !didStop
                    {
                        didStop = true
                        // Clears forwardGroups via iterator reset paths / stop.
                        synthesizer?.stop()
                    }
                    return [element]
                }
            }
        }

        let tokenizer = ReentrantTokenizer()
        let engine = PrefetchingTTSEngine(prefetchResult: 5)
        let french = Language("fr")
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first"),
                textElement("second"),
                textElement("third"),
            ],
            engine: engine,
            tokenizerFactory: { language in tokenizer.makeTokenizer(language: language) }
        )
        tokenizer.synthesizer = synthesizer

        synthesizer.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.prefetchedTexts.contains("second")
        }
        synthesizer.config.defaultLanguage = french
        engine.completeSpeech()
        // stop() from inside retokenize must not trap on forwardGroups[index].
        try await waitUntil { synthesizer.state == .stopped }
    }

    func testReleasingSynthesizerDuringSpeechAllowsDeinitAndCancelsPlayback() async throws {
        let engine = PrefetchingTTSEngine(cancelsPendingPrefetch: true)
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )
        weak let weakSynthesizer = synthesizer

        synthesizer?.start()
        try await waitUntil { engine.spokenTexts == ["first"] }

        // Drop last external reference while speak is suspended. Weak playback
        // worker must not keep the synthesizer alive.
        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
    }

    func testReleasingSynthesizerDuringForwardPrefetchWaitAllowsDeinit() async throws {
        let engine = PrefetchingTTSEngine(
            defersPrefetch: true,
            cancelsPendingPrefetch: true
        )
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            elements: [textElement("first"), textElement("second")],
            engine: engine
        )
        weak let weakSynthesizer = synthesizer

        synthesizer?.start()
        try await waitUntil {
            engine.spokenTexts == ["first"] && engine.hasPendingPrefetch
        }
        engine.completeSpeech()
        try await waitUntil {
            synthesizer?.isWaitingForForwardPrefetchForTesting == true
        }

        // Hung on inter-sentence waiter; weak worker + independent registry
        // must allow deinit (which resumes waiters / cancels tasks).
        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        try await waitUntil { engine.cancelPrefetchCount >= 1 || !engine.hasPendingPrefetch }
    }

    func testReleasingSynthesizerDuringLiveIteratorLoadAllowsDeinit() async throws {
        let iterator = GatedArrayContentIterator(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
            ],
            startIndex: 0,
            gatedNextCall: 2,
            delaysCancellationExit: true
        )
        // Non-prefetching engine so continuation uses live iterator load.
        let engine = SpeechEngine()
        var synthesizer: PublicationSpeechSynthesizer? = try makeSynthesizer(
            contentService: IteratorContentService(iteratorFactory: { iterator }),
            engine: engine
        )
        weak let weakSynthesizer = synthesizer

        synthesizer?.start()
        try await waitUntil { engine.spokenTexts == ["first"] }
        engine.completeSpeech()
        // After first ends with no waterline, live load of second suspends on gate.
        try await waitUntil { iterator.hasSuspendedNext }

        synthesizer = nil
        try await waitUntil { weakSynthesizer == nil }
        // Cancelled playback may still be draining a delayed-cancellation next().
        try await waitUntil {
            if iterator.hasSuspendedCleanup {
                iterator.openCleanupGate()
            }
            return !iterator.hasSuspendedNext && iterator.activeCallCount == 0
        }
    }

    func testPrefetchTokenizationFailureDoesNotSkipContent() async throws {
        let tokenizer = FailingOnceTokenizer(failingText: "second")
        let engine = PrefetchingTTSEngine()
        let synthesizer = try makeSynthesizer(
            elements: [
                textElement("first", href: "first.xhtml"),
                textElement("second", href: "second.xhtml"),
                textElement("third", href: "third.xhtml"),
            ],
            engine: engine,
            tokenizerFactory: { _ in tokenizer.tokenize }
        )

        synthesizer.start()
        try await waitUntil { tokenizer.didFail }
        engine.completeSpeech()
        try await waitUntil { engine.spokenTexts == ["first", "second"] }
        synthesizer.stop()
    }

    func testIncompatibleSelectedVoiceFallsBackToUtteranceLanguage() async throws {
        let zh = Language("zh")
        let en = Language("en")
        let voice = TTSVoice(
            identifier: "system.zh",
            language: zh,
            name: "Chinese",
            gender: .unspecified,
            quality: nil
        )
        let engine = PrefetchingTTSEngine(availableVoices: [voice])
        let locator = locator(text: .init(highlight: "English text"))
        let element = TextContentElement(
            locator: locator,
            role: .body,
            segments: [.init(
                locator: locator,
                text: "English text",
                attributes: [ContentAttribute(key: .language, value: en)]
            )]
        )
        let synthesizer = try makeSynthesizer(elements: [element], engine: engine)
        synthesizer.config.voiceIdentifier = voice.identifier

        synthesizer.start()
        try await waitUntil { engine.spokenVoiceOrLanguages.count == 1 }
        guard case let .right(language) = engine.spokenVoiceOrLanguages[0] else {
            return XCTFail("Expected language fallback")
        }
        XCTAssertEqual(language, en)
        synthesizer.stop()
    }

    func testUnmatchedStartTextKeepsTheFirstBlock() throws {
        let synthesizer = try makeSynthesizer()
        let start = locator(text: .init(before: "unmatched", highlight: "text"))
        synthesizer.start(from: start)

        let first = try synthesizer.tokenize(textElement("first"))
        let second = try synthesizer.tokenize(textElement("second"))

        XCTAssertEqual((first.first as? TextContentElement)?.text, "first")
        XCTAssertEqual((second.first as? TextContentElement)?.text, "second")
        synthesizer.stop()
    }

    func testStartTextWithoutBeforeKeepsTheFirstBlock() throws {
        let synthesizer = try makeSynthesizer()
        synthesizer.start(from: locator(text: .init(highlight: "first")))

        let result = try synthesizer.tokenize(textElement("first"))

        XCTAssertEqual((result.first as? TextContentElement)?.text, "first")
        synthesizer.stop()
    }

    func testStartTextTrimsTheOriginalWhitespacePrefix() throws {
        let synthesizer = try makeSynthesizer()
        let before = "one \n\t "
        synthesizer.start(from: locator(text: .init(before: before, highlight: "two")))

        let result = try synthesizer.tokenize(textElement(before + "two"))

        XCTAssertEqual((result.first as? TextContentElement)?.text, "two")
        synthesizer.stop()
    }

    func testStartTextMapsRawWhitespacePrefixToNormalizedSegments() throws {
        let synthesizer = try makeSynthesizer()
        let before = "one  \n\t"
        synthesizer.start(from: locator(text: .init(before: before, highlight: before + "two")))
        let normalized = "one two"
        let rawLocator = locator(text: .init(highlight: before + "two"))
        let element = TextContentElement(
            locator: rawLocator,
            role: .body,
            segments: [.init(locator: rawLocator, text: normalized)]
        )

        let result = try synthesizer.tokenize(element)

        XCTAssertEqual((result.first as? TextContentElement)?.text, "two")
        synthesizer.stop()
    }

    func testStartTextTrimsBeforeDefaultSentenceTokenization() throws {
        let synthesizer = try makeSynthesizer(
            tokenizerFactory: PublicationSpeechSynthesizer.defaultTokenizerFactory
        )
        let before = "First sentence.  "
        synthesizer.start(from: locator(text: .init(before: before, highlight: "Second sentence.")))

        let result = try synthesizer.tokenize(textElement(before + "Second sentence."))

        XCTAssertEqual((result.first as? TextContentElement)?.text, "Second sentence.")
        XCTAssertEqual(result.count, 1)
        synthesizer.stop()
    }

    func testFailedStartTextTokenizationDoesNotTrimNextElement() throws {
        let tokenizer = FailingOnceTokenizer(failingText: "first")
        let synthesizer = try makeSynthesizer(tokenizerFactory: { _ in tokenizer.tokenize })
        synthesizer.start(from: locator(text: .init(before: "prefix ")))

        XCTAssertThrowsError(try synthesizer.tokenize(textElement("prefix first")))
        let result = try synthesizer.tokenize(textElement("prefix second"))

        XCTAssertEqual((result.first as? TextContentElement)?.text, "prefix second")
        synthesizer.stop()
    }

    private func makeSynthesizer(
        elements: [TextContentElement] = [],
        startIndex: Int = 0,
        contentService: ContentService? = nil,
        engine: TTSEngine = AVTTSEngine(),
        tokenizerFactory: @escaping PublicationSpeechSynthesizer.TokenizerFactory = { _ in { [$0] } }
    ) throws -> PublicationSpeechSynthesizer {
        try XCTUnwrap(
            PublicationSpeechSynthesizer(
                publication: Publication(
                    manifest: Manifest(metadata: Metadata(title: "Test")),
                    servicesBuilder: .init(content: { _ in
                        contentService ??
                            ArrayContentService(elements: elements, startIndex: startIndex)
                    })
                ),
                audioSession: NoopAudioSession(),
                engineFactory: { engine },
                tokenizerFactory: tokenizerFactory
            )
        )
    }

    private func textElement(
        _ text: String,
        href: String = "chapter.xhtml"
    ) -> TextContentElement {
        let locator = locator(href: href, text: .init(highlight: text))
        return TextContentElement(
            locator: locator,
            role: .body,
            segments: [.init(locator: locator, text: text)]
        )
    }

    private func locator(
        href: String = "chapter.xhtml",
        text: Locator.Text = .init()
    ) -> Locator {
        Locator(href: AnyURL(string: href)!, mediaType: .xhtml, text: text)
    }
}

private final class FailingOnceTokenizer {
    private let failingText: String
    private(set) var didFail = false

    init(failingText: String) {
        self.failingText = failingText
    }

    func tokenize(_ content: ContentElement) throws -> [ContentElement] {
        if
            !didFail,
            (content as? TextContentElement)?.text == failingText
        {
            didFail = true
            throw TestError.failedTokenization
        }
        return [content]
    }

    private enum TestError: Error {
        case failedTokenization
    }
}

@MainActor
private final class ReentrantTokenizer {
    var cancelOnSecondTokenization = false
    var onSecondTokenization: (() -> Void)?
    var cancelOnThirdTokenization = false
    var onThirdTokenization: (() -> Void)?
    var makeSecondEmpty = false

    func tokenize(_ content: ContentElement) -> [ContentElement] {
        let text = (content as? TextContentElement)?.text
        if makeSecondEmpty, text == "second" {
            return []
        }
        if
            cancelOnSecondTokenization,
            text == "second"
        {
            cancelOnSecondTokenization = false
            onSecondTokenization?()
        }
        if cancelOnThirdTokenization, text == "third" {
            cancelOnThirdTokenization = false
            onThirdTokenization?()
        }
        return [content]
    }
}

@MainActor
private final class RecordingSpeechSynthesizerDelegate: PublicationSpeechSynthesizerDelegate {
    private(set) var states: [PublicationSpeechSynthesizer.State] = []
    var onStateChange: ((PublicationSpeechSynthesizer.State) -> Void)?

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        states.append(state)
        onStateChange?(state)
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {}
}

private final class IteratorContentService: ContentService {
    private let iteratorFactory: () -> ContentIterator

    init(iteratorFactory: @escaping () -> ContentIterator) {
        self.iteratorFactory = iteratorFactory
    }

    func content(from start: Locator?) -> Content? {
        IteratorContent(iteratorFactory: iteratorFactory)
    }
}

private final class IteratorContent: Content {
    private let iteratorFactory: () -> ContentIterator

    init(iteratorFactory: @escaping () -> ContentIterator) {
        self.iteratorFactory = iteratorFactory
    }

    func iterator() -> ContentIterator {
        iteratorFactory()
    }
}

private final class IteratorFactory {
    private var iterators: [ContentIterator]

    init(_ iterators: [ContentIterator]) {
        self.iterators = iterators
    }

    func make() -> ContentIterator {
        iterators.removeFirst()
    }
}

private final class ArrayContentService: ContentService {
    private let elements: [TextContentElement]
    private let startIndex: Int

    init(elements: [TextContentElement], startIndex: Int) {
        self.elements = elements
        self.startIndex = startIndex
    }

    func content(from start: Locator?) -> Content? {
        let index = start.flatMap { locator in
            elements.firstIndex {
                $0.locator.href.isEquivalentTo(locator.href)
            }
        } ?? startIndex
        return ArrayContent(elements: elements, startIndex: index)
    }
}

private final class ArrayContent: Content {
    private let elements: [TextContentElement]
    private let startIndex: Int

    init(elements: [TextContentElement], startIndex: Int) {
        self.elements = elements
        self.startIndex = startIndex
    }

    func iterator() -> ContentIterator {
        ArrayContentIterator(elements: elements, startIndex: startIndex)
    }
}

private final class ArrayContentIterator: ContentIterator {
    private let elements: [TextContentElement]
    private var index: Int

    init(elements: [TextContentElement], startIndex: Int) {
        self.elements = elements
        index = startIndex - 1
    }

    func next() async throws -> ContentElement? {
        guard index + 1 < elements.count else { return nil }
        index += 1
        return elements[index]
    }

    func previous() async throws -> ContentElement? {
        guard index - 1 >= 0 else { return nil }
        index -= 1
        return elements[index]
    }
}

private final class GatedArrayContentIterator: ContentIterator, @unchecked Sendable {
    private let lock = NSLock()
    private let elements: [TextContentElement]
    private let gatedNextCall: Int
    private let gatedPreviousCall: Int?
    private let throwingNextCall: Int?
    private let returnsElementOnCancellation: Bool
    /// When true, a cancelled gated `next` waits on `openCleanupGate` before
    /// throwing — holding the "task slot cleared, body still in next" window.
    private let delaysCancellationExit: Bool
    private var index: Int
    private var nextCalls = 0
    private var previousCalls = 0
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateCancelled = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var cleanupReleased = false
    private var previousGateContinuation: CheckedContinuation<Void, Never>?
    private var previousGateCancelled = false

    init(
        elements: [TextContentElement],
        startIndex: Int,
        gatedNextCall: Int,
        gatedPreviousCall: Int? = nil,
        throwingNextCall: Int? = nil,
        returnsElementOnCancellation: Bool = false,
        delaysCancellationExit: Bool = false
    ) {
        self.elements = elements
        index = startIndex - 1
        self.gatedNextCall = gatedNextCall
        self.gatedPreviousCall = gatedPreviousCall
        self.throwingNextCall = throwingNextCall
        self.returnsElementOnCancellation = returnsElementOnCancellation
        self.delaysCancellationExit = delaysCancellationExit
    }

    var nextCallCount: Int {
        lock.withLock { nextCalls }
    }

    var previousCallCount: Int {
        lock.withLock { previousCalls }
    }

    var maximumConcurrentCalls: Int {
        lock.withLock { maximumActiveCalls }
    }

    var activeCallCount: Int {
        lock.withLock { activeCalls }
    }

    var hasSuspendedNext: Bool {
        lock.withLock { gateContinuation != nil }
    }

    var hasSuspendedCleanup: Bool {
        lock.withLock { cleanupContinuation != nil }
    }

    var hasSuspendedPrevious: Bool {
        lock.withLock { previousGateContinuation != nil }
    }

    func next() async throws -> ContentElement? {
        let call = lock.withLock {
            nextCalls += 1
            activeCalls += 1
            maximumActiveCalls = max(maximumActiveCalls, activeCalls)
            return nextCalls
        }
        defer { lock.withLock { activeCalls -= 1 } }
        if call == gatedNextCall {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeImmediately = lock.withLock {
                        if gateCancelled {
                            return true
                        }
                        gateContinuation = continuation
                        return false
                    }
                    if resumeImmediately {
                        continuation.resume()
                    }
                }
            } onCancel: {
                let continuation = lock.withLock {
                    gateCancelled = true
                    defer { gateContinuation = nil }
                    return gateContinuation
                }
                continuation?.resume()
            }
            if delaysCancellationExit, Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeImmediately = lock.withLock {
                        if cleanupReleased {
                            return true
                        }
                        cleanupContinuation = continuation
                        return false
                    }
                    if resumeImmediately {
                        continuation.resume()
                    }
                }
            }
            if !returnsElementOnCancellation {
                try Task.checkCancellation()
            }
        }
        if call == throwingNextCall {
            throw TestError.next
        }
        return lock.withLock {
            guard index + 1 < elements.count else { return nil }
            index += 1
            return elements[index]
        }
    }

    func previous() async throws -> ContentElement? {
        let call = lock.withLock {
            previousCalls += 1
            activeCalls += 1
            maximumActiveCalls = max(maximumActiveCalls, activeCalls)
            return previousCalls
        }
        defer { lock.withLock { activeCalls -= 1 } }
        if call == gatedPreviousCall {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeImmediately = lock.withLock {
                        if previousGateCancelled { return true }
                        previousGateContinuation = continuation
                        return false
                    }
                    if resumeImmediately { continuation.resume() }
                }
            } onCancel: {
                let continuation = lock.withLock {
                    previousGateCancelled = true
                    defer { previousGateContinuation = nil }
                    return previousGateContinuation
                }
                continuation?.resume()
            }
            // Match next(): when returnsElementOnCancellation, still return the
            // element after a successful gate resume even if the task is cancelled.
            if !returnsElementOnCancellation {
                try Task.checkCancellation()
            }
        }
        return lock.withLock {
            guard index - 1 >= 0 else { return nil }
            index -= 1
            return elements[index]
        }
    }

    func openGate() {
        let continuation = lock.withLock {
            defer { gateContinuation = nil }
            return gateContinuation
        }
        continuation?.resume()
    }

    func openCleanupGate() {
        let continuation = lock.withLock {
            cleanupReleased = true
            defer { cleanupContinuation = nil }
            return cleanupContinuation
        }
        continuation?.resume()
    }

    private enum TestError: Error {
        case next
    }
}

@MainActor
private final class SpeechEngine: TTSEngine {
    nonisolated let availableVoices: [TTSVoice] = []
    private(set) var spokenTexts: [String] = []
    private(set) var maximumConcurrentSpeeches = 0
    private var speechContinuations: [CheckedContinuation<Result<Void, TTSError>, Never>] = []
    private let completesOnCancellation: Bool
    private var activeSpeechCount = 0

    init(completesOnCancellation: Bool = true) {
        self.completesOnCancellation = completesOnCancellation
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        activeSpeechCount += 1
        maximumConcurrentSpeeches = max(maximumConcurrentSpeeches, activeSpeechCount)
        defer { activeSpeechCount -= 1 }
        spokenTexts.append(utterance.text)
        onSpeakRange(utterance.text.startIndex ..< utterance.text.endIndex)
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                speechContinuations.append($0)
            }
        } onCancel: {
            if completesOnCancellation {
                Task { @MainActor [weak self] in
                    self?.completeSpeech()
                }
            }
        }
    }

    func completeSpeech() {
        guard !speechContinuations.isEmpty else { return }
        speechContinuations.removeFirst().resume(returning: .success(()))
    }
}

@MainActor
private final class PrefetchingTTSEngine: TTSPrefetchingEngine {
    nonisolated let availableVoices: [TTSVoice]
    private(set) var prefetchedIdentifiers: [UUID?] = []
    private(set) var spokenIdentifiers: [UUID?] = []
    private(set) var spokenTexts: [String] = []
    private(set) var spokenVoiceOrLanguages: [Either<TTSVoice, Language>] = []
    private(set) var prefetchedTexts: [String] = []
    private(set) var cancelPrefetchCount = 0
    private(set) var maximumConcurrentPrefetches = 0
    private var speechContinuations: [CheckedContinuation<Result<Void, TTSError>, Never>] = []
    private var prefetchContinuation: CheckedContinuation<TimeInterval?, Never>?
    private let defersPrefetch: Bool
    private let deferPrefetchOnCall: Int?
    private let prefetchResult: TimeInterval?
    private let prefetchDurations: [String: TimeInterval]
    private let rejectsDurationExceedingMaximum: Bool
    private let clampsPrefetchDuration: Bool
    private let cancelsPendingPrefetch: Bool
    private var prefetchCallCount = 0
    private var activePrefetchCount = 0

    init(
        availableVoices: [TTSVoice] = [],
        defersPrefetch: Bool = false,
        deferPrefetchOnCall: Int? = nil,
        prefetchResult: TimeInterval? = 5,
        prefetchDurations: [String: TimeInterval] = [:],
        rejectsDurationExceedingMaximum: Bool = false,
        clampsPrefetchDuration: Bool = true,
        cancelsPendingPrefetch: Bool = false
    ) {
        self.availableVoices = availableVoices
        self.defersPrefetch = defersPrefetch
        self.deferPrefetchOnCall = deferPrefetchOnCall
        self.prefetchResult = prefetchResult
        self.prefetchDurations = prefetchDurations
        self.rejectsDurationExceedingMaximum = rejectsDurationExceedingMaximum
        self.clampsPrefetchDuration = clampsPrefetchDuration
        self.cancelsPendingPrefetch = cancelsPendingPrefetch
    }

    var hasPendingPrefetch: Bool {
        prefetchContinuation != nil
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        spokenIdentifiers.append(utterance.prefetchIdentifier)
        spokenTexts.append(utterance.text)
        spokenVoiceOrLanguages.append(utterance.voiceOrLanguage)
        onSpeakRange(utterance.text.startIndex ..< utterance.text.endIndex)
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                speechContinuations.append($0)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeSpeech()
            }
        }
    }

    func prefetch(
        _ utterance: TTSUtterance,
        maximumDuration: TimeInterval
    ) async -> TimeInterval? {
        activePrefetchCount += 1
        maximumConcurrentPrefetches = max(maximumConcurrentPrefetches, activePrefetchCount)
        defer { activePrefetchCount -= 1 }
        prefetchedIdentifiers.append(utterance.prefetchIdentifier)
        prefetchedTexts.append(utterance.text)
        prefetchCallCount += 1
        guard
            defersPrefetch || deferPrefetchOnCall == prefetchCallCount
        else {
            let duration = prefetchDurations[utterance.text] ?? prefetchResult
            guard
                !rejectsDurationExceedingMaximum || duration.map({ $0 <= maximumDuration }) != false
            else {
                return nil
            }
            return duration.map { clampsPrefetchDuration ? min($0, maximumDuration) : $0 }
        }
        return await withCheckedContinuation {
            prefetchContinuation = $0
        }
    }

    func cancelPrefetch() {
        cancelPrefetchCount += 1
        if cancelsPendingPrefetch {
            prefetchContinuation?.resume(returning: nil)
            prefetchContinuation = nil
        }
    }

    func completeSpeech() {
        guard !speechContinuations.isEmpty else { return }
        speechContinuations.removeFirst().resume(returning: .success(()))
    }

    func completePrefetch(returning duration: TimeInterval? = 5) {
        prefetchContinuation?.resume(returning: duration)
        prefetchContinuation = nil
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Timed out waiting for condition")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private struct TestTimeoutError: Error {}

private final class TimeoutResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Hard timeout that does **not** wait for a hung operation to finish.
///
/// Unlike `withThrowingTaskGroup`, returning on timeout does not join the
/// operation task. `onTimeout` should unblock fake engines / gated iterators
/// so the orphaned task can eventually exit without blocking the test process.
@MainActor
private func withHardTimeout<T: Sendable>(
    _ timeout: TimeInterval,
    onTimeout: @MainActor @escaping () -> Void = {},
    operation: @MainActor @escaping () async -> T
) async throws -> T {
    let box = TimeoutResultBox<T>()
    let task = Task { @MainActor in
        let value = await operation()
        box.set(value)
    }

    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let value = box.get() {
            _ = await task.value
            return value
        }
        if Date() >= deadline {
            task.cancel()
            onTimeout()
            XCTFail("Hard-timed out after \(timeout)s")
            throw TestTimeoutError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private final class NoopAudioSession: AudioSessionManaging {
    func start(with user: AudioSessionUser, isPlaying: Bool) {}

    func end(for user: AudioSessionUser) {}

    func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool) {}
}
