//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class AVTTSEngineTests: XCTestCase, @preconcurrency AVTTSEngineDelegate {
    private var utterances: [AVSpeechUtterance] = []

    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        utterances.append(utterance)
    }

    func testSwitchingVoiceKeepsTheCurrentSpeakTaskUntilTheRestartFinishes() async throws {
        let output = TestSpeechOutput()
        let engine = makeEngine(output: output)
        let completion = TestCompletion()
        let firstSpoken = expectation(description: "first utterance spoken")
        output.onSpeak = { _ in firstSpoken.fulfill() }
        let task = Task { @MainActor in
            let result = await engine.speak(TTSUtterance(text: "first second", delay: 1, voiceOrLanguage: .right(Language("en")))) { _ in }
            completion.didComplete = true
            return result
        }

        await fulfillment(of: [firstSpoken], timeout: 1)
        output.onSpeak = nil
        let first = try XCTUnwrap(output.utterances.first)
        XCTAssertEqual(first.preUtteranceDelay, 1)
        let synthesizer = AVSpeechSynthesizer()
        engine.speechSynthesizer(synthesizer, didStart: first)
        engine.speechSynthesizer(
            synthesizer,
            willSpeakRangeOfSpeechString: NSRange(location: 6, length: 6),
            utterance: first
        )

        XCTAssertTrue(engine.switchVoice(to: nil))
        engine.speechSynthesizer(synthesizer, didCancel: first)

        let restarted = try XCTUnwrap(output.utterances.last)
        XCTAssertEqual(restarted.speechString, "second")
        XCTAssertEqual(restarted.preUtteranceDelay, 0)
        XCTAssertFalse(completion.didComplete)
        XCTAssertEqual(output.utterances.count, 2)

        engine.speechSynthesizer(synthesizer, didStart: restarted)
        engine.speechSynthesizer(synthesizer, didFinish: restarted)
        if case .failure = await task.value {
            XCTFail("The restarted task should succeed")
        }
        XCTAssertTrue(completion.didComplete)
    }

    func testCancellingAQueuedTaskCompletesItsSpeakCall() async throws {
        let output = TestSpeechOutput()
        let engine = makeEngine(output: output)
        let firstSpoken = expectation(description: "first utterance spoken")
        output.onSpeak = { _ in firstSpoken.fulfill() }
        let firstTask = Task { @MainActor in
            await engine.speak(TTSUtterance(text: "first", delay: 0, voiceOrLanguage: .right(Language("en")))) { _ in }
        }

        await fulfillment(of: [firstSpoken], timeout: 1)
        output.onSpeak = nil
        let first = try XCTUnwrap(output.utterances.first)
        let synthesizer = AVSpeechSynthesizer()
        engine.speechSynthesizer(synthesizer, didStart: first)

        let stopRequested = expectation(description: "first utterance stop requested")
        output.onStop = { stopRequested.fulfill() }
        let queuedTask = Task { @MainActor in
            await engine.speak(TTSUtterance(text: "second", delay: 0, voiceOrLanguage: .right(Language("en")))) { _ in }
        }
        await fulfillment(of: [stopRequested], timeout: 1)
        output.onStop = nil
        queuedTask.cancel()
        if case .failure = await queuedTask.value {
            XCTFail("The cancelled queued task should finish")
        }
        engine.speechSynthesizer(synthesizer, didCancel: first)

        if case .failure = await firstTask.value {
            XCTFail("The active task should finish")
        }
        XCTAssertEqual(output.utterances.count, 1)
    }

    func testNewSpeakDuringVoiceRestartCompletesBothTasks() async throws {
        let output = TestSpeechOutput()
        let engine = makeEngine(output: output)
        let firstSpoken = expectation(description: "first utterance spoken")
        output.onSpeak = { _ in firstSpoken.fulfill() }
        let firstTask = Task { @MainActor in
            await engine.speak(TTSUtterance(text: "first second", delay: 0, voiceOrLanguage: .right(Language("en")))) { _ in }
        }

        await fulfillment(of: [firstSpoken], timeout: 1)
        output.onSpeak = nil
        let first = try XCTUnwrap(output.utterances.first)
        let synthesizer = AVSpeechSynthesizer()
        engine.speechSynthesizer(synthesizer, didStart: first)
        engine.speechSynthesizer(
            synthesizer,
            willSpeakRangeOfSpeechString: NSRange(location: 6, length: 6),
            utterance: first
        )
        XCTAssertTrue(engine.switchVoice(to: nil))

        let nextEntered = expectation(description: "next speak entered")
        let nextTask = Task { @MainActor in
            nextEntered.fulfill()
            return await engine.speak(TTSUtterance(text: "third", delay: 0, voiceOrLanguage: .right(Language("en")))) { _ in }
        }
        await fulfillment(of: [nextEntered], timeout: 1)
        engine.speechSynthesizer(synthesizer, didCancel: first)

        let next = try XCTUnwrap(output.utterances.last)
        XCTAssertEqual(next.speechString, "third")
        XCTAssertEqual(output.utterances.count, 2)
        engine.speechSynthesizer(synthesizer, didStart: next)
        engine.speechSynthesizer(synthesizer, didFinish: next)

        if case .failure = await firstTask.value {
            XCTFail("The restarted task should finish")
        }
        if case .failure = await nextTask.value {
            XCTFail("The queued task should finish")
        }
    }

    private func makeEngine(output: TestSpeechOutput) -> AVTTSEngine {
        AVTTSEngine(
            delegate: self,
            speechOutput: output,
            resolveVoiceIdentifier: { _ in nil },
            resolveVoiceLanguage: { _ in nil }
        )
    }
}

private final class TestSpeechOutput: AVSpeechOutput {
    private(set) var utterances: [AVSpeechUtterance] = []
    var onSpeak: ((AVSpeechUtterance) -> Void)?
    var onStop: (() -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
        onSpeak?(utterance)
    }

    func stop() {
        onStop?()
    }
}

@MainActor
private final class TestCompletion {
    var didComplete = false
}
