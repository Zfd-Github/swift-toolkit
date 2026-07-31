//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class TTSEngineIsolationTests: XCTestCase {
    func testExistentialSpeakKeepsRangeCallbackOnMainActor() async {
        let engine: TTSEngine = ImmediateTTSEngine()
        let utterance = TTSUtterance(
            text: "test",
            delay: 0,
            voiceOrLanguage: .right(Language("en"))
        )
        var callbackCount = 0

        let result = await engine.speak(utterance) { _ in
            callbackCount += 1
        }

        if case .failure = result {
            XCTFail("The immediate engine should succeed")
        }
        XCTAssertEqual(callbackCount, 1)
    }
}

private final class ImmediateTTSEngine: TTSEngine {
    let availableVoices: [TTSVoice] = []

    @MainActor
    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        onSpeakRange(utterance.text.startIndex ..< utterance.text.endIndex)
        return .success(())
    }
}
