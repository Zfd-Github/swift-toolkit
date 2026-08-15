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
private class LifecycleTestSpreadView: EPUBSpreadView {
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
private final class SuspendingJavaScriptSpreadView: LifecycleTestSpreadView {
    private var evaluationCompletions: [(Any?, Error?) -> Void] = []

    var pendingEvaluationCount: Int {
        evaluationCompletions.count
    }

    override var javaScriptEvaluationTimeout: TimeInterval {
        0.05
    }

    override func beginJavaScriptEvaluation(
        _ script: String,
        completionHandler: @escaping (Any?, Error?) -> Void
    ) {
        evaluationCompletions.append(completionHandler)
    }

    func completeEvaluations(with error: Error = CancellationError()) {
        let completions = evaluationCompletions
        evaluationCompletions.removeAll()
        completions.forEach { $0(nil, error) }
    }
}

@MainActor
@Suite(.serialized)
struct EPUBSpreadViewLifecycleTests {
    @Test("operation deadline bounds a JavaScript request and poisons its generation")
    func operationDeadlinePoisonsJavaScriptGeneration() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        let originalGeneration = spread.webViewGeneration
        let operation = NavigationOperation(
            operationID: 7,
            intent: .absolute("deadline"),
            timeout: .milliseconds(20)
        )

        let result = await spread.evaluateScript(
            "never-finishes",
            operation: operation
        )

        #expect(result.result.isTimedOut)
        #expect(spread.isPoisoned)
        #expect(spread.webViewGeneration != originalGeneration)
        #expect(spread.pendingEvaluationCount == 1)
        spread.completeEvaluations()
        await nextMainRunLoop()
        #expect(spread.isPoisoned)
        spread.clear()
        withExtendedLifetime(container) {}
    }

    @Test("cancelling a submitted position mutation poisons its WebView generation")
    func cancelledMutationPoisonsJavaScriptGeneration() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        let originalGeneration = spread.webViewGeneration
        let operation = NavigationOperation(
            operationID: 9,
            intent: .absolute("cancelled-mutation"),
            timeout: .seconds(1)
        )

        let evaluation = Task { @MainActor in
            await spread.evaluateScript(
                "window.scrollBy({ left: 320 });",
                operation: operation,
                effect: .positionMutation
            )
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })
        evaluation.cancel()

        #expect(await (evaluation.value).result.isCancelled)
        #expect(spread.isPoisoned)
        #expect(spread.webViewGeneration != originalGeneration)
        spread.completeEvaluations()
        spread.clear()
        withExtendedLifetime(container) {}
    }

    @Test("cancelling a submitted read-only script keeps its WebView generation")
    func cancelledReadOnlyScriptKeepsJavaScriptGeneration() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        let originalGeneration = spread.webViewGeneration
        let operation = NavigationOperation(
            operationID: 10,
            intent: .absolute("cancelled-query"),
            timeout: .seconds(1)
        )

        let evaluation = Task { @MainActor in
            await spread.evaluateScript(
                "readium.findFirstVisibleLocator()",
                operation: operation,
                effect: .readOnly
            )
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })
        evaluation.cancel()

        #expect(await (evaluation.value).result.isCancelled)
        #expect(!spread.isPoisoned)
        #expect(spread.webViewGeneration == originalGeneration)
        spread.completeEvaluations()
        spread.clear()
        withExtendedLifetime(container) {}
    }

    @Test("operation deadline includes waiting for spread load")
    func operationDeadlineIncludesSpreadLoad() async {
        let spread = makeSpreadView()
        let operation = NavigationOperation(
            operationID: 8,
            intent: .absolute("load-deadline"),
            timeout: .milliseconds(20)
        )

        let result = await spread.evaluateScript("never-submitted", operation: operation)

        #expect(result.result.isTimedOut)
        #expect(spread.isPoisoned)
        spread.clear()
    }

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

    @Test("task cancellation releases a pending JavaScript evaluation")
    func cancellationReleasesPendingEvaluation() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        var result: Result<Any, Error>?
        let evaluation = Task { @MainActor in
            result = await spread.evaluateScript("never-calls-back")
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })

        evaluation.cancel()
        let didFinish = await waitUntil(attempts: 50) { result != nil }
        #expect(didFinish)
        #expect(result?.isFailure == true)

        if !didFinish {
            spread.completeEvaluations()
        }
        await evaluation.value
        spread.clear()
        withExtendedLifetime(container) {}
    }

    @Test("clear releases every pending JavaScript evaluation")
    func clearReleasesPendingEvaluations() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        var results: [Result<Any, Error>] = []
        let first = Task { @MainActor in
            await results.append(spread.evaluateScript("first"))
        }
        let second = Task { @MainActor in
            await results.append(spread.evaluateScript("second"))
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 2 })

        spread.clear()
        let didFinish = await waitUntil(attempts: 50) { results.count == 2 }
        #expect(didFinish)
        let allFailed = results.allSatisfy(\.isFailure)
        #expect(allFailed)

        if !didFinish {
            spread.completeEvaluations()
        }
        await first.value
        await second.value
        withExtendedLifetime(container) {}
    }

    @Test("WebContent termination releases pending JavaScript evaluation")
    func webContentTerminationReleasesPendingEvaluation() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        var result: Result<Any, Error>?
        let evaluation = Task { @MainActor in
            result = await spread.evaluateScript("terminated")
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })

        spread.webViewWebContentProcessDidTerminate(spread.webView)
        let didFinish = await waitUntil(attempts: 50) { result != nil }
        #expect(didFinish)
        #expect(result?.isFailure == true)

        if !didFinish {
            spread.completeEvaluations()
        }
        await evaluation.value
        spread.clear()
        withExtendedLifetime(container) {}
    }

    @Test("navigation failure releases pending JavaScript evaluation")
    func navigationFailureReleasesPendingEvaluation() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        var result: Result<Any, Error>?
        let evaluation = Task { @MainActor in
            result = await spread.evaluateScript("failed-navigation")
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })

        spread.webView(
            spread.webView,
            didFail: nil,
            withError: URLError(.cannotDecodeContentData)
        )
        let didFinish = await waitUntil(attempts: 50) { result != nil }
        #expect(didFinish)
        #expect(result?.isFailure == true)

        if !didFinish {
            spread.completeEvaluations()
        }
        await evaluation.value
        withExtendedLifetime(container) {}
    }

    @Test("pending JavaScript evaluation has a bounded timeout")
    func pendingEvaluationTimesOut() async {
        let (spread, container) = await makeLoadedSuspendingSpreadView()
        var result: Result<Any, Error>?
        let evaluation = Task { @MainActor in
            result = await spread.evaluateScript("never-finishes")
        }
        #expect(await waitUntil { spread.pendingEvaluationCount == 1 })

        let didFinish = await waitUntil(attempts: 50) { result != nil }
        #expect(didFinish)
        #expect(result?.isFailure == true)

        if !didFinish {
            spread.completeEvaluations()
        }
        await evaluation.value
        spread.clear()
        withExtendedLifetime(container) {}
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

    @Test("task cancellation releases a pending spread load waiter")
    func cancellationReleasesSpreadLoadWaiter() async {
        let spread = makeSpreadView()
        var didFinishWaiting = false
        let waiting = Task { @MainActor in
            await spread.spreadLoaded()
            didFinishWaiting = true
        }
        await nextMainRunLoop()

        waiting.cancel()
        let didFinish = await waitUntil(attempts: 50) { didFinishWaiting }
        #expect(didFinish)

        if !didFinish {
            spread.clear()
        }
        await waiting.value
        spread.clear()
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
        makeSpreadView(ofType: LifecycleTestSpreadView.self)
    }

    private func makeLoadedSuspendingSpreadView() async -> (
        SuspendingJavaScriptSpreadView,
        UIView
    ) {
        let spread = makeSpreadView(ofType: SuspendingJavaScriptSpreadView.self)
        let container = UIView()
        container.addSubview(spread)
        spread.loadDocumentReportingSpreadLoaded()
        await spread.spreadLoaded()
        return (spread, container)
    }

    private func makeSpreadView<Spread: LifecycleTestSpreadView>(
        ofType type: Spread.Type
    ) -> Spread {
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

        return type.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [],
            animatedLoad: false
        )
    }

    private func waitUntil(
        attempts: Int = 500,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
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

private extension Result {
    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
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
