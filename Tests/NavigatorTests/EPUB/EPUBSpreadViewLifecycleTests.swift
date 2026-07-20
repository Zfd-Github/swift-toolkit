//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

@MainActor
private final class LifecycleTestSpreadView: EPUBSpreadView {
    override func loadSpread() {}

    func loadDocumentReportingSpreadLoaded() {
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body><script>
            window.webkit.messageHandlers.spreadLoaded.postMessage({});
            </script></body></html>
            """,
            baseURL: nil
        )
    }
}

@MainActor
@Suite(.serialized)
struct EPUBSpreadViewLifecycleTests {
    @Test("clear resumes existing and future callbacks exactly once")
    func clearResumesCallbacksExactlyOnce() async {
        let waitingSpread = makeSpreadView()
        var waitingCallbackCount = 0
        waitingSpread.whenSpreadLoaded {
            waitingCallbackCount += 1
        }

        waitingSpread.clear()
        #expect(await waitUntil { waitingCallbackCount == 1 })

        waitingSpread.clear()
        await nextMainRunLoop()
        #expect(waitingCallbackCount == 1)

        let clearedSpread = makeSpreadView()
        clearedSpread.clear()
        await nextMainRunLoop()
        var lateCallbackCount = 0
        clearedSpread.whenSpreadLoaded {
            lateCallbackCount += 1
        }

        let didResumeLateCallback = await waitUntil { lateCallbackCount == 1 }
        #expect(didResumeLateCallback)

        if !didResumeLateCallback {
            // Let the legacy implementation release the callback so RED does
            // not leave work suspended in the test process.
            clearedSpread.clear()
            _ = await waitUntil { lateCallbackCount == 1 }
        }

        clearedSpread.clear()
        await nextMainRunLoop()
        #expect(lateCallbackCount == 1)
    }

    @Test("operations captured after clear do not remain suspended")
    func operationsAfterClearFinish() async {
        let spreadLoadedSpread = makeSpreadView()
        spreadLoadedSpread.clear()
        var didFinishWaiting = false
        let waitingTask = Task { @MainActor in
            await spreadLoadedSpread.spreadLoaded()
            didFinishWaiting = true
        }

        let didResumeWaiter = await waitUntil { didFinishWaiting }
        #expect(didResumeWaiter)

        if !didResumeWaiter {
            spreadLoadedSpread.clear()
        }
        await waitingTask.value

        let evaluationSpread = makeSpreadView()
        evaluationSpread.clear()
        var didFinishEvaluation = false
        let evaluationTask = Task { @MainActor in
            _ = await evaluationSpread.evaluateScript("1")
            didFinishEvaluation = true
        }

        let didEvaluate = await waitUntil { didFinishEvaluation }
        #expect(didEvaluate)

        if !didEvaluate {
            evaluationSpread.clear()
        }
        await evaluationTask.value
    }

    @Test("normal loading waits for spreadLoaded before resuming")
    func normalLoadingWaitsThenResumes() async {
        let spread = makeSpreadView()
        let container = UIView()
        container.addSubview(spread)

        var completionCount = 0
        let waitingTask = Task { @MainActor in
            await spread.spreadLoaded()
            completionCount += 1
        }

        await nextMainRunLoop()
        #expect(completionCount == 0)

        spread.loadDocumentReportingSpreadLoaded()
        #expect(await waitUntil { completionCount == 1 })

        spread.clear()
        await waitingTask.value
        #expect(completionCount == 1)
    }

    private func makeSpreadView() -> LifecycleTestSpreadView {
        let link = Link(href: "chapter.xhtml", mediaType: .xhtml)
        let readingOrder = [link]
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test"),
                readingOrder: readingOrder
            )
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder,
            config: .init()
        )
        let spread = EPUBSpread.single(EPUBSingleSpread(
            resource: EPUBSpreadResource(index: 0, link: link)
        ))

        return LifecycleTestSpreadView(
            viewModel: viewModel,
            spread: spread,
            scripts: [],
            animatedLoad: false
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
