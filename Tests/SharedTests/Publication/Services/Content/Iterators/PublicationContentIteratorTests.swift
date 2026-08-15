//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
@testable import ReadiumShared
import Testing

struct PublicationContentIteratorTests {
    @Test func cancellationWhileCrossingResourcesDoesNotCommitCandidate() async throws {
        let gate = AsyncGate()
        let factory = TestIteratorFactory(gate: gate)
        let links = [
            Link(href: "first.html", mediaType: .html),
            Link(href: "second.html", mediaType: .html),
        ]
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "test"), readingOrder: links),
            container: ProxyContainer(entries: Set(links.map { $0.url() })) { _ in
                DataResource(string: "")
            }
        )
        let iterator = PublicationContentIterator(
            publication: publication,
            start: nil,
            resourceContentIteratorFactories: [factory]
        )

        let first = try await iterator.next() as? TextContentElement
        let second = try await iterator.next() as? TextContentElement
        #expect(first?.text == "first")
        #expect(second?.text == "second")

        let crossing = Task { try await iterator.next() }
        guard await gate.waitForWaiters() else {
            crossing.cancel()
            gate.open()
            Issue.record("Timed out waiting for the next resource")
            return
        }
        crossing.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await crossing.value
        }

        let previous = try await iterator.previous() as? TextContentElement
        #expect(previous?.text == "first")
        #expect(try await (iterator.next() as? TextContentElement)?.text == "second")
        #expect(try await (iterator.next() as? TextContentElement)?.text == "third")
        #expect(factory.secondResourceIteratorCount == 1)
    }
}

private final class TestIteratorFactory: ResourceContentIteratorFactory {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var _secondResourceIteratorCount = 0

    var secondResourceIteratorCount: Int {
        lock.withLock { _secondResourceIteratorCount }
    }

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func make(
        publication: Publication,
        readingOrderIndex: Int,
        resource: Resource,
        locator: Locator
    ) -> ContentIterator? {
        switch readingOrderIndex {
        case 0:
            return TestArrayIterator(
                elements: [testElement("first", href: "first.html"), testElement("second", href: "first.html")],
                startsAtEnd: locator.locations.progression == 1
            )
        case 1:
            lock.withLock { _secondResourceIteratorCount += 1 }
            return GatedTestIterator(gate: gate)
        default:
            return nil
        }
    }
}

private final class TestArrayIterator: ContentIterator {
    private let elements: [ContentElement]
    private var index: Int

    init(elements: [ContentElement], startsAtEnd: Bool) {
        self.elements = elements
        index = startsAtEnd ? elements.count : -1
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

private final class GatedTestIterator: ContentIterator {
    private let gate: AsyncGate

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func next() async throws -> ContentElement? {
        try await withTaskCancellationHandler {
            await gate.wait()
            try Task.checkCancellation()
            return testElement("third", href: "second.html")
        } onCancel: {
            gate.open()
        }
    }

    func previous() async throws -> ContentElement? {
        nil
    }
}

private func testElement(_ text: String, href: String) -> TextContentElement {
    let locator = Locator(href: href, mediaType: .html)
    return TextContentElement(
        locator: locator,
        role: .body,
        segments: [.init(locator: locator, text: text)]
    )
}
