//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

extension Locator {
    init(href: String, mediaType: MediaType, title: String? = nil, locations: Locations = .init(), text: Text = .init()) {
        self.init(href: AnyURL(string: href)!, mediaType: mediaType, title: title, locations: locations, text: text)
    }
}

extension ContentElement {
    func equatable() -> AnyEquatableContentElement {
        AnyEquatableContentElement(self)
    }
}

final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    var waiterCount: Int { lock.withLock { continuations.count } }
    var isOpen: Bool { lock.withLock { opened } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if opened { return true }
                continuations.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func waitForWaiters(
        _ count: Int = 1,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while waiterCount < count {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    func open() {
        let continuations = lock.withLock {
            opened = true
            defer { self.continuations = [] }
            return self.continuations
        }
        continuations.forEach { $0.resume() }
    }
}
