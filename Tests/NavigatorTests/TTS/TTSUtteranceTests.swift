//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import ReadiumShared
import XCTest

final class TTSUtteranceTests: XCTestCase {
    func testPublicInitializerPreservesValues() {
        let language = Language(code: .bcp47("zh-CN"))
        let utterance = TTSUtterance(
            text: "测试句子",
            delay: 0.25,
            voiceOrLanguage: .right(language)
        )

        XCTAssertEqual(utterance.text, "测试句子")
        XCTAssertEqual(utterance.delay, 0.25)
        XCTAssertEqual(utterance.language, language)
    }
}
