//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct EPUBPageTurnSnapshotTests {
    @Test("capture leases are serialized")
    func captureLeasesAreSerialized() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let first = FakeSnapshotSpread(pageIndex: 0)
        let second = FakeSnapshotSpread(pageIndex: 1)
        first.isCaptureBlocked = true

        let firstTask = Task { try await capture(with: provider, spread: first) }
        #expect(await waitUntil { first.captureCount == 1 })

        let secondTask = Task { try await capture(with: provider, spread: second) }
        await nextMainRunLoop()
        #expect(second.captureCount == 0)

        first.isCaptureBlocked = false
        #expect(try await firstTask.value != nil)
        #expect(try await secondTask.value != nil)
        #expect(first.restoreCount == 1)
        #expect(second.restoreCount == 1)
    }

    @Test("success is invisible until two restore frames and suppression cleanup")
    func successPublishesAfterCompleteRestore() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.requiredRestoreFrames = 2
        let target = spread.identity
        var publishedImage: UIImage?
        var didPublish = false
        let task = Task {
            publishedImage = try await capture(with: provider, spread: spread)
            didPublish = true
        }

        #expect(await waitUntil { spread.didStartRestore })
        #expect(!didPublish)
        #expect(provider.cachedSnapshot(for: target) == nil)
        #expect(spread.isProgressionSuppressed)

        spread.allowedRestoreFrames = 1
        #expect(await waitUntil { spread.completedRestoreFrames == 1 })
        #expect(!didPublish)
        #expect(provider.cachedSnapshot(for: target) == nil)
        #expect(spread.isProgressionSuppressed)

        spread.allowedRestoreFrames = 2
        try await task.value
        #expect(didPublish)
        #expect(publishedImage != nil)
        #expect(provider.cachedSnapshot(for: target) != nil)
        #expect(spread.completedRestoreFrames == 2)
        #expect(!spread.isProgressionSuppressed)
        #expect(spread.events == ["capture", "restore-offset", "frame-1", "frame-2", "restore-complete"])
    }

    @Test("errors and cancellation are invisible until complete restore")
    func failureOutcomesPublishAfterCompleteRestore() async {
        for outcome in [CaptureOutcome.error, .cancellation] {
            let provider = EPUBPageTurnSnapshotProvider()
            let spread = FakeSnapshotSpread(pageIndex: outcome == .error ? 2 : 3)
            spread.requiredRestoreFrames = 2
            if outcome == .error {
                spread.captureError = ProbeError.captureFailed
            } else {
                spread.isCaptureBlocked = true
            }
            var didPublishOutcome = false
            let task = Task {
                defer { didPublishOutcome = true }
                do {
                    let image = try await capture(with: provider, spread: spread)
                    #expect(outcome == .cancellation)
                    #expect(image == nil)
                } catch {
                    #expect(outcome == .error)
                }
            }

            if outcome == .cancellation {
                #expect(await waitUntil { spread.captureCount == 1 })
                task.cancel()
            }
            #expect(await waitUntil { spread.didStartRestore })
            #expect(!didPublishOutcome)
            #expect(provider.cachedSnapshot(for: spread.identity) == nil)
            #expect(spread.isProgressionSuppressed)

            spread.allowedRestoreFrames = 1
            #expect(await waitUntil { spread.completedRestoreFrames == 1 })
            #expect(!didPublishOutcome)
            #expect(provider.cachedSnapshot(for: spread.identity) == nil)

            spread.allowedRestoreFrames = 2
            await task.value
            #expect(didPublishOutcome)
            #expect(provider.cachedSnapshot(for: spread.identity) == nil)
            #expect(spread.completedRestoreFrames == 2)
            #expect(!spread.isProgressionSuppressed)
            #expect(spread.offset == spread.originalOffset)
            #expect(spread.progression == spread.originalProgression)
        }
    }

    @Test("a cancelled cache hit returns nil without recapturing")
    func cancelledCacheHitReturnsNil() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        #expect(try await capture(with: provider, spread: spread) != nil)

        let task = Task { try await capture(with: provider, spread: spread) }
        task.cancel()

        #expect(try await task.value == nil)
        #expect(spread.captureCount == 1)
        #expect(spread.restoreCount == 1)
    }

    @Test("cache hits avoid a second capture")
    func cacheHit() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)

        let first = try await capture(with: provider, spread: spread)
        let second = try await capture(with: provider, spread: spread)

        #expect(first === second)
        #expect(spread.captureCount == 1)
        #expect(spread.restoreCount == 1)
        #expect(provider.cacheCount == 1)
    }

    @Test("invalidation removes existing cache and isolates revisions")
    func existingCacheInvalidationAndRevisionIsolation() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        let target = spread.identity
        let first = try await capture(with: provider, spread: spread)
        #expect(first != nil)
        #expect(provider.cachedSnapshot(for: target) === first)

        provider.invalidate()
        #expect(provider.cachedSnapshot(for: target) == nil)
        #expect(provider.cacheCount == 0)

        spread.imageColor = .purple
        let second = try await capture(with: provider, spread: spread)
        #expect(second != nil)
        #expect(second !== first)
        #expect(provider.cachedSnapshot(for: target) === second)
        #expect(spread.captureCount == 2)
    }

    @Test("in-flight prior revision never populates the new revision")
    func staleCaptureCannotCrossRevision() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.isCaptureBlocked = true
        let target = spread.identity
        let task = Task { try await capture(with: provider, spread: spread) }
        #expect(await waitUntil { spread.captureCount == 1 })

        provider.invalidate()
        spread.isCaptureBlocked = false

        #expect(try await task.value == nil)
        #expect(provider.cachedSnapshot(for: target) == nil)
        #expect(provider.cacheCount == 0)
        #expect(spread.restoreCount == 1)
    }

    @Test("cache retains only the declared previous current next identities")
    func cacheRetainsOnlyDeclaredAdjacentPages() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let previous = FakeSnapshotSpread(pageIndex: 0)
        let current = FakeSnapshotSpread(pageIndex: 1)
        let next = FakeSnapshotSpread(pageIndex: 2)
        let unrelated = FakeSnapshotSpread(pageIndex: 9)
        provider.retainSnapshots(
            previous: previous.identity,
            current: current.identity,
            next: next.identity
        )

        for spread in [previous, current, next, unrelated] {
            #expect(try await capture(with: provider, spread: spread) != nil)
        }

        #expect(provider.cacheCount == 3)
        #expect(provider.cachedSnapshot(for: previous.identity) != nil)
        #expect(provider.cachedSnapshot(for: current.identity) != nil)
        #expect(provider.cachedSnapshot(for: next.identity) != nil)
        #expect(provider.cachedSnapshot(for: unrelated.identity) == nil)
        #expect(Set(provider.cachedTargets) == Set([previous.identity, current.identity, next.identity]))

        provider.retainSnapshots(previous: previous.identity, current: nil, next: next.identity)
        #expect(provider.cachedSnapshot(for: current.identity) == nil)
        #expect(Set(provider.cachedTargets) == Set([previous.identity, next.identity]))

        provider.retainSnapshots(previous: previous.identity, current: current.identity, next: nil)
        #expect(try await capture(with: provider, spread: current) != nil)
        #expect(provider.cachedSnapshot(for: next.identity) == nil)
        #expect(Set(provider.cachedTargets) == Set([previous.identity, current.identity]))

        provider.retainSnapshots(previous: nil, current: current.identity, next: next.identity)
        #expect(try await capture(with: provider, spread: next) != nil)
        #expect(provider.cachedSnapshot(for: previous.identity) == nil)
        #expect(provider.cachedSnapshot(for: current.identity) != nil)
        #expect(provider.cachedSnapshot(for: next.identity) != nil)
        #expect(provider.cachedSnapshot(for: unrelated.identity) == nil)
        #expect(Set(provider.cachedTargets) == Set([current.identity, next.identity]))

        provider.retainSnapshots(previous: current.identity, current: next.identity, next: unrelated.identity)
        #expect(try await capture(with: provider, spread: unrelated) != nil)
        #expect(Set(provider.cachedTargets) == Set([current.identity, next.identity, unrelated.identity]))
    }

    @Test("capture publishes only for the same ready target identity")
    func readyTargetIdentity() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.isCaptureBlocked = true
        let requestedTarget = spread.identity
        let task = Task { try await capture(with: provider, spread: spread, target: requestedTarget) }
        #expect(await waitUntil { spread.captureCount == 1 })

        spread.isIdentityAvailable = false
        spread.isCaptureBlocked = false

        #expect(try await task.value == nil)
        #expect(provider.cachedSnapshot(for: requestedTarget) == nil)
        #expect(spread.restoreCount == 1)
    }

    @Test("settle waits for both restore frames and resumes two waiters")
    func settleWaitersObserveCompleteRestore() async {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.isCaptureBlocked = true
        spread.requiredRestoreFrames = 2
        let captureTask = Task { try? await capture(with: provider, spread: spread) }
        #expect(await waitUntil { spread.captureCount == 1 })

        var settled = 0
        let first = Task { await provider.settle(); settled += 1 }
        let second = Task { await provider.settle(); settled += 1 }
        #expect(await waitUntil { spread.didStartRestore })
        #expect(settled == 0)
        #expect(spread.locationPublishCount == 0)

        spread.allowedRestoreFrames = 1
        #expect(await waitUntil { spread.completedRestoreFrames == 1 })
        #expect(settled == 0)
        #expect(provider.isIdle == false)

        spread.allowedRestoreFrames = 2
        await first.value
        await second.value
        _ = await captureTask.value
        #expect(settled == 2)
        #expect(spread.restoreCount == 1)
        #expect(provider.isIdle)
        #expect(spread.offset == spread.originalOffset)
        #expect(spread.progression == spread.originalProgression)
    }

    @Test("capture error is settled only after completed restore")
    func settleAfterCaptureError() async {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.captureError = ProbeError.captureFailed
        spread.requiredRestoreFrames = 2
        let captureTask = Task { try? await capture(with: provider, spread: spread) }
        #expect(await waitUntil { spread.didStartRestore })

        let settleTask = Task { await provider.settle() }
        spread.allowedRestoreFrames = 1
        #expect(await waitUntil { spread.completedRestoreFrames == 1 })
        #expect(!provider.isIdle)

        spread.allowedRestoreFrames = 2
        await settleTask.value
        _ = await captureTask.value
        #expect(provider.isIdle)
        #expect(spread.restoreCount == 1)
        #expect(spread.locationPublishCount == 0)
    }

    @Test("named deferred slots drain reload, preferences, then interaction and re-enable input")
    func namedDeferredMutationSlotsDrainInOrder() async throws {
        let provider = EPUBPageTurnSnapshotProvider()
        let spread = FakeSnapshotSpread(pageIndex: 1)
        spread.isCaptureBlocked = true
        spread.requiredRestoreFrames = 2
        let captureTask = Task { try? await capture(with: provider, spread: spread) }
        #expect(await waitUntil { spread.captureCount == 1 })

        provider.deferPreferences { spread.mutationEvents.append("preferences:first") }
        provider.deferPreferences { spread.mutationEvents.append("preferences:last") }
        provider.deferReload { spread.mutationEvents.append("reload") }
        provider.deferReload { spread.mutationEvents.append("reload") }
        provider.deferPageTurnInteraction {
            spread.mutationEvents.append("interaction:first")
        }
        provider.deferPageTurnInteraction {
            spread.mutationEvents.append("interaction:last")
        }
        #expect(!provider.isInputEnabled)

        let settleTask = Task { await provider.settle() }
        #expect(await waitUntil { spread.didStartRestore })
        spread.allowedRestoreFrames = 1
        #expect(await waitUntil { spread.completedRestoreFrames == 1 })
        #expect(spread.mutationEvents.isEmpty)
        #expect(!provider.isInputEnabled)

        spread.allowedRestoreFrames = 2
        await settleTask.value
        _ = await captureTask.value
        #expect(spread.mutationEvents == [
            "reload",
            "preferences:last",
            "interaction:last",
        ])
        #expect(provider.isInputEnabled)
        #expect(provider.isIdle)

        spread.isCaptureBlocked = false
        spread.requiredRestoreFrames = 0
        spread.replaceIdentity()
        #expect(try await capture(with: provider, spread: spread) != nil)
        #expect(spread.captureCount == 2)
    }

    @Test("page-turn interaction changes immediately when no snapshot lease exists")
    func pageTurnInteractionDrainsImmediatelyWithoutCaptureLease() {
        let provider = EPUBPageTurnSnapshotProvider()
        var mutationCount = 0

        provider.deferPageTurnInteraction { mutationCount += 1 }

        #expect(mutationCount == 1)
        #expect(provider.isInputEnabled)
        #expect(provider.isIdle)
    }

    @Test("selection and active media independently suppress capture without mutations")
    func selectionAndMediaIndependentlySuppressCapture() async throws {
        let selected = FakeSnapshotSpread(pageIndex: 1, hasSelection: true)
        let playing = FakeSnapshotSpread(pageIndex: 1, hasActiveMedia: true)

        for blockedSpread in [selected, playing] {
            let provider = EPUBPageTurnSnapshotProvider()
            let offset = blockedSpread.offset
            let progression = blockedSpread.progression
            #expect(blockedSpread.hasSelection != blockedSpread.hasActiveMedia)

            let image = try await capture(with: provider, spread: blockedSpread)

            #expect(image == nil)
            #expect(blockedSpread.captureCount == 0)
            #expect(blockedSpread.restoreCount == 0)
            #expect(blockedSpread.offset == offset)
            #expect(blockedSpread.progression == progression)
            #expect(blockedSpread.locationPublishCount == 0)
        }
    }

    @Test("selection or media becoming active during capture suppresses publication")
    func captureBecomingBlockedDoesNotPublishOrCache() async throws {
        for blocksWithSelection in [true, false] {
            let provider = EPUBPageTurnSnapshotProvider()
            let spread = FakeSnapshotSpread(pageIndex: 1)
            spread.isCaptureBlocked = true
            let target = spread.identity
            let task = Task { try await capture(with: provider, spread: spread) }
            #expect(await waitUntil { spread.captureCount == 1 })

            if blocksWithSelection {
                spread.hasSelection = true
            } else {
                spread.hasActiveMedia = true
            }
            spread.isCaptureBlocked = false

            #expect(try await task.value == nil)
            #expect(spread.restoreCount == 1)
            #expect(provider.cachedSnapshot(for: target) == nil)
            #expect(provider.cacheCount == 0)
        }
    }

    private func capture(
        with provider: EPUBPageTurnSnapshotProvider,
        spread: FakeSnapshotSpread,
        target: EPUBPageTurnSnapshotTargetIdentity? = nil
    ) async throws -> UIImage? {
        let target = target ?? spread.identity
        return try await provider.capture(
            target: target,
            sourceIdentity: { spread.isIdentityAvailable ? spread.identity : nil },
            isBlocked: { spread.hasSelection || spread.hasActiveMedia },
            capture: { try await spread.capture() },
            restore: { await spread.restore() }
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 5_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class FakeSnapshotSpread {
    let originalOffset = CGPoint(x: 320, y: 0)
    let originalProgression = 0.25
    var offset: CGPoint
    var progression: Double
    var hasSelection: Bool
    var hasActiveMedia: Bool
    var isCaptureBlocked = false
    var isIdentityAvailable = true
    var captureError: Error?
    var imageColor = UIColor.blue
    var requiredRestoreFrames = 0
    var allowedRestoreFrames = 0
    var captureCount = 0
    var restoreCount = 0
    var locationPublishCount = 0
    var completedRestoreFrames = 0
    var events: [String] = []
    var mutationEvents: [String] = []
    private(set) var didStartRestore = false
    private(set) var isProgressionSuppressed = false
    private let paginationToken = NSObject()
    private var spreadToken = NSObject()
    private let resourceIndex: Int
    private let pageIndex: Int

    var identity: EPUBPageTurnSnapshotTargetIdentity {
        EPUBPageTurnSnapshotTargetIdentity(
            pagination: paginationToken,
            spread: spreadToken,
            resourceIndex: resourceIndex,
            pageIndex: pageIndex
        )
    }

    init(
        resourceIndex: Int = 0,
        pageIndex: Int,
        hasSelection: Bool = false,
        hasActiveMedia: Bool = false
    ) {
        self.resourceIndex = resourceIndex
        self.pageIndex = pageIndex
        self.hasSelection = hasSelection
        self.hasActiveMedia = hasActiveMedia
        offset = originalOffset
        progression = originalProgression
    }

    func replaceIdentity() {
        spreadToken = NSObject()
    }

    func capture() async throws -> UIImage {
        captureCount += 1
        events.append("capture")
        isProgressionSuppressed = true
        offset.x += 320
        progression = 0.5
        while isCaptureBlocked {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000)
        }
        if let captureError { throw captureError }
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            imageColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func restore() async {
        didStartRestore = true
        offset = originalOffset
        progression = originalProgression
        events.append("restore-offset")
        if requiredRestoreFrames > 0 {
            for frame in 1 ... requiredRestoreFrames {
                while allowedRestoreFrames < frame { await Task.yield() }
                completedRestoreFrames = frame
                events.append("frame-\(frame)")
            }
        }
        isProgressionSuppressed = false
        restoreCount += 1
        events.append("restore-complete")
    }
}

private enum CaptureOutcome {
    case error
    case cancellation
}

private enum ProbeError: Error {
    case captureFailed
}
