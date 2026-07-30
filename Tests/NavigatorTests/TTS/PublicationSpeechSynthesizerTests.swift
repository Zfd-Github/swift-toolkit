//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

final class PublicationSpeechSynthesizerTests: XCTestCase {
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

    private func makeSynthesizer(
        tokenizerFactory: @escaping PublicationSpeechSynthesizer.TokenizerFactory = { _ in { [$0] } }
    ) throws -> PublicationSpeechSynthesizer {
        try XCTUnwrap(
            PublicationSpeechSynthesizer(
                publication: Publication(
                    manifest: Manifest(metadata: Metadata(title: "Test")),
                    servicesBuilder: .init(content: { _ in EmptyContentService() })
                ),
                audioSession: NoopAudioSession(),
                tokenizerFactory: tokenizerFactory
            )
        )
    }

    private func textElement(_ text: String) -> TextContentElement {
        let locator = locator(text: .init(highlight: text))
        return TextContentElement(
            locator: locator,
            role: .body,
            segments: [.init(locator: locator, text: text)]
        )
    }

    private func locator(text: Locator.Text = .init()) -> Locator {
        Locator(href: AnyURL(string: "chapter.xhtml")!, mediaType: .xhtml, text: text)
    }
}

private final class EmptyContentService: ContentService {
    func content(from start: Locator?) -> Content? {
        EmptyContent()
    }
}

private final class EmptyContent: Content {
    func iterator() -> ContentIterator {
        EmptyContentIterator()
    }
}

private final class EmptyContentIterator: ContentIterator {
    func next() async throws -> ContentElement? {
        nil
    }

    func previous() async throws -> ContentElement? {
        nil
    }
}

private final class NoopAudioSession: AudioSessionManaging {
    func start(with user: AudioSessionUser, isPlaying: Bool) {}

    func end(for user: AudioSessionUser) {}

    func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool) {}
}
