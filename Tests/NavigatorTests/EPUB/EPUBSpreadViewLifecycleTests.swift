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

    func loadSameURLMediaDocuments() {
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body>
            <iframe id="first" srcdoc="<audio id='media'></audio><script>
            globalThis.setActive = active => {
                const media = document.getElementById('media');
                Object.defineProperty(media, 'paused', { configurable: true, get: () => !active });
                Object.defineProperty(media, 'ended', { configurable: true, get: () => false });
                media.dispatchEvent(new Event(active ? 'play' : 'pause'));
            };
            </script>"></iframe>
            <iframe id="second" srcdoc="<audio id='media'></audio><script>
            globalThis.setActive = active => {
                const media = document.getElementById('media');
                Object.defineProperty(media, 'paused', { configurable: true, get: () => !active });
                Object.defineProperty(media, 'ended', { configurable: true, get: () => false });
                media.dispatchEvent(new Event(active ? 'play' : 'pause'));
            };
            </script>"></iframe>
            <script>window.webkit.messageHandlers.spreadLoaded.postMessage({});</script>
            </body></html>
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

    @Test("active media tracks same-URL frames independently")
    func activeMediaTracksSameURLFramesIndependently() async {
        let spread = makeSpreadView()
        let container = UIView()
        container.addSubview(spread)
        spread.loadSameURLMediaDocuments()

        #expect(await waitUntilAsync {
            await spread.evaluateScript(
                "typeof document.getElementById('first')?.contentWindow.setActive === 'function'"
            ).booleanValue == true
        })

        _ = await spread.evaluateScript("document.getElementById('first').contentWindow.setActive(true)")
        #expect(await waitUntil { spread.hasActiveMedia })

        _ = await spread.evaluateScript("document.getElementById('second').contentWindow.setActive(true)")
        try? await Task.sleep(nanoseconds: 100_000_000)
        _ = await spread.evaluateScript("document.getElementById('first').contentWindow.setActive(false)")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(spread.hasActiveMedia)
        spread.clear()
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

    private func waitUntilAsync(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

private extension Result where Success == Any, Failure == Error {
    var booleanValue: Bool? {
        guard case let .success(value) = self else {
            return nil
        }
        return value as? Bool
    }
}
