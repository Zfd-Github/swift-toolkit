//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

struct EPUBPageTurnSnapshotTargetIdentity: Hashable {
    private let pagination: ObjectIdentifier
    private let spread: ObjectIdentifier
    let resourceIndex: Int
    let pageIndex: Int

    init(
        pagination: AnyObject,
        spread: AnyObject,
        resourceIndex: Int,
        pageIndex: Int
    ) {
        self.pagination = ObjectIdentifier(pagination)
        self.spread = ObjectIdentifier(spread)
        self.resourceIndex = resourceIndex
        self.pageIndex = pageIndex
    }
}

@MainActor
final class EPUBPageTurnSnapshotProvider {
    private struct CacheKey: Hashable {
        let revision: UInt64
        let target: EPUBPageTurnSnapshotTargetIdentity
    }

    private var renderRevision: UInt64 = 0
    private var cache: [CacheKey: UIImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private var retainedTargets: Set<EPUBPageTurnSnapshotTargetIdentity>?

    private var hasCaptureLease = false
    private var leaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationSettleWaiters: [UUID: CheckedContinuation<NavigationResult, Never>] = [:]
    private var operationCaptureSettleWaiters: [UUID: CheckedContinuation<NavigationResult, Never>] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activeCaptureTask: Task<UIImage, Error>?
    private var activeDeferredMutationTask: Task<Void, Never>?
    private var pendingDeferredMutation: (@MainActor () async -> Void)?
    private var cancellationGeneration: UInt64 = 0

    private var deferredReload: (() -> Void)?
    private var deferredPreferences: (() -> Void)?
    private var deferredPageTurnInteraction: (() -> Void)?

    var isIdle: Bool {
        !hasCaptureLease
            && leaseWaiters.isEmpty
            && !hasDeferredMutations
            && activeDeferredMutationTask == nil
            && pendingDeferredMutation == nil
    }

    var isInputEnabled: Bool {
        isIdle
    }

    private var isCaptureRestored: Bool {
        !hasCaptureLease
            && leaseWaiters.isEmpty
            && !hasDeferredMutations
    }

    var cacheCount: Int {
        cache.count
    }

    var revision: UInt64 {
        renderRevision
    }

    var cachedTargets: [EPUBPageTurnSnapshotTargetIdentity] {
        cache.keys
            .filter { $0.revision == renderRevision }
            .map(\.target)
    }

    func cachedSnapshot(for target: EPUBPageTurnSnapshotTargetIdentity) -> UIImage? {
        cache[CacheKey(revision: renderRevision, target: target)]
    }

    func retainSnapshots(
        previous: EPUBPageTurnSnapshotTargetIdentity?,
        current: EPUBPageTurnSnapshotTargetIdentity?,
        next: EPUBPageTurnSnapshotTargetIdentity?
    ) {
        retainedTargets = Set([previous, current, next].compactMap { $0 })
        trimCache()
    }

    func invalidate() {
        renderRevision &+= 1
        cache.removeAll()
        cacheOrder.removeAll()
        cancellationGeneration &+= 1
        activeCaptureTask?.cancel()
    }

    func deferReload(_ mutation: @escaping () -> Void) {
        deferredReload = mutation
        cancelActiveCapture()
        drainDeferredMutationsIfPossible()
    }

    func deferPreferences(_ mutation: @escaping () -> Void) {
        deferredPreferences = mutation
        cancelActiveCapture()
        drainDeferredMutationsIfPossible()
    }

    /// Defers a recognizer-mode change until an in-flight snapshot has restored
    /// its source hierarchy. The page-turn style itself remains immediately
    /// observable; only UIKit's competing recognizers wait for the lease.
    func deferPageTurnInteraction(_ mutation: @escaping () -> Void) {
        deferredPageTurnInteraction = mutation
        cancelActiveCapture()
        drainDeferredMutationsIfPossible()
    }

    /// Extends the snapshot barrier across an asynchronous mutation which was
    /// released by one of the deferred callbacks above. `settle()` must not
    /// report idle merely because an executor request was enqueued.
    func performDeferredMutation(_ mutation: @escaping @MainActor () async -> Void) {
        guard activeDeferredMutationTask == nil else {
            pendingDeferredMutation = mutation
            return
        }
        activeDeferredMutationTask = Task { @MainActor [weak self] in
            await mutation()
            guard let self else { return }
            activeDeferredMutationTask = nil
            if let pendingDeferredMutation {
                self.pendingDeferredMutation = nil
                performDeferredMutation(pendingDeferredMutation)
                return
            }
            drainDeferredMutationsIfPossible()
        }
    }

    func settle() async {
        cancelActiveCapture()
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            settleWaiters.append(continuation)
        }
    }

    /// Waits for snapshot restoration without allowing a stuck capture to hold
    /// a navigation operation beyond its absolute deadline.
    func settle(operation: NavigationOperationToken) async -> NavigationResult {
        if isIdle {
            return operation.check() ?? .applied
        }
        if let result = operation.check() { return result }
        cancelActiveCapture()
        let id = UUID()
        return await withTaskGroup(of: NavigationResult.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return .cancelled }
                return await withCheckedContinuation { continuation in
                    if self.isIdle {
                        continuation.resume(returning: operation.check() ?? .applied)
                    } else {
                        self.operationSettleWaiters[id] = continuation
                    }
                }
            }
            group.addTask { @MainActor in
                await operation.waitForCancellation()
            }
            let result = await group.next() ?? .cancelled
            cancelOperationSettleWaiter(id, with: result)
            group.cancelAll()
            return result
        }
    }

    /// Waits only for the capture hierarchy to be restored. Deferred mutations
    /// are submitted to the navigation executor and can safely remain queued
    /// behind the operation which is calling this method. Waiting for their
    /// tasks here would deadlock when they are queued on that same executor.
    func settleCapture(operation: NavigationOperationToken) async -> NavigationResult {
        if isCaptureRestored {
            return operation.check() ?? .applied
        }
        if let result = operation.check() { return result }
        cancelActiveCapture()
        let id = UUID()
        return await withTaskGroup(of: NavigationResult.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return .cancelled }
                return await withCheckedContinuation { continuation in
                    if self.isCaptureRestored {
                        continuation.resume(returning: operation.check() ?? .applied)
                    } else {
                        self.operationCaptureSettleWaiters[id] = continuation
                    }
                }
            }
            group.addTask { @MainActor in
                await operation.waitForCancellation()
            }
            let result = await group.next() ?? .cancelled
            cancelOperationCaptureSettleWaiter(id, with: result)
            group.cancelAll()
            return result
        }
    }

    func waitUntilIdle() async {
        guard !isIdle, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isIdle, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                idleWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelIdleWaiter(id)
            }
        }
    }

    func capture(
        target: EPUBPageTurnSnapshotTargetIdentity,
        sourceIdentity: @escaping () -> EPUBPageTurnSnapshotTargetIdentity?,
        isBlocked: @escaping () -> Bool,
        capture: @escaping () async throws -> UIImage,
        restore: @escaping () async -> Void
    ) async throws -> UIImage? {
        let requestedRevision = renderRevision
        let requestedCancellationGeneration = cancellationGeneration
        let key = CacheKey(revision: requestedRevision, target: target)
        guard !Task.isCancelled, !isBlocked() else { return nil }
        if let image = cache[key] { return image }

        await acquireCaptureLease()
        guard
            !Task.isCancelled,
            requestedRevision == renderRevision,
            requestedCancellationGeneration == cancellationGeneration,
            sourceIdentity() == target,
            !isBlocked()
        else {
            releaseCaptureLease()
            return nil
        }
        if let image = cache[key] {
            releaseCaptureLease()
            guard
                !Task.isCancelled,
                requestedRevision == renderRevision,
                requestedCancellationGeneration == cancellationGeneration,
                sourceIdentity() == target,
                !isBlocked()
            else {
                return nil
            }
            return image
        }

        let task = Task { @MainActor in try await capture() }
        activeCaptureTask = task
        let result: Result<UIImage, Error>
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            result = .success(image)
        } catch {
            result = .failure(error)
        }

        activeCaptureTask = nil
        await restore()

        releaseCaptureLease()

        guard
            !Task.isCancelled,
            requestedRevision == renderRevision,
            requestedCancellationGeneration == cancellationGeneration,
            sourceIdentity() == target,
            !isBlocked()
        else {
            return nil
        }
        switch result {
        case let .success(image):
            store(image, for: key)
            return image
        case .failure(_ as CancellationError):
            return nil
        case let .failure(error):
            throw error
        }
    }

    private var hasDeferredMutations: Bool {
        deferredReload != nil
            || deferredPreferences != nil
            || deferredPageTurnInteraction != nil
    }

    private func acquireCaptureLease() async {
        if !hasCaptureLease {
            hasCaptureLease = true
            return
        }
        await withCheckedContinuation { continuation in
            leaseWaiters.append(continuation)
        }
    }

    private func releaseCaptureLease() {
        drainDeferredMutations()
        if leaseWaiters.isEmpty {
            hasCaptureLease = false
            drainDeferredMutations()
            resumeWaitersIfIdle()
        } else {
            leaseWaiters.removeFirst().resume()
        }
    }

    private func cancelActiveCapture() {
        cancellationGeneration &+= 1
        activeCaptureTask?.cancel()
    }

    private func drainDeferredMutationsIfPossible() {
        guard !hasCaptureLease else { return }
        drainDeferredMutations()
        resumeWaitersIfIdle()
    }

    private func drainDeferredMutations() {
        let reload = deferredReload
        let preferences = deferredPreferences
        let pageTurnInteraction = deferredPageTurnInteraction
        deferredReload = nil
        deferredPreferences = nil
        deferredPageTurnInteraction = nil
        reload?()
        preferences?()
        pageTurnInteraction?()
    }

    private func resumeWaitersIfIdle() {
        resumeCaptureWaitersIfIdle()
        guard isIdle else { return }
        let waiters = settleWaiters
        settleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let operationWaiters = operationSettleWaiters.values
        operationSettleWaiters.removeAll()
        operationWaiters.forEach { $0.resume(returning: .applied) }
        let idleWaiters = Array(idleWaiters.values)
        self.idleWaiters.removeAll()
        idleWaiters.forEach { $0.resume() }
    }

    private func resumeCaptureWaitersIfIdle() {
        guard isCaptureRestored else { return }
        let operationWaiters = operationCaptureSettleWaiters.values
        operationCaptureSettleWaiters.removeAll()
        operationWaiters.forEach { $0.resume(returning: .applied) }
    }

    private func cancelIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelOperationSettleWaiter(
        _ id: UUID,
        with result: NavigationResult
    ) {
        operationSettleWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func cancelOperationCaptureSettleWaiter(
        _ id: UUID,
        with result: NavigationResult
    ) {
        operationCaptureSettleWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func store(_ image: UIImage, for key: CacheKey) {
        if let retainedTargets, !retainedTargets.contains(key.target) { return }
        cache[key] = image
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        trimCache()
    }

    private func trimCache() {
        if let retainedTargets {
            cache = cache.filter { retainedTargets.contains($0.key.target) }
            cacheOrder.removeAll { !retainedTargets.contains($0.target) }
        }
        while cacheOrder.count > 3 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
