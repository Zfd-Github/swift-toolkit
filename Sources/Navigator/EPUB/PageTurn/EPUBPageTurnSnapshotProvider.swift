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
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activeCaptureTask: Task<UIImage, Error>?
    private var cancellationGeneration: UInt64 = 0

    private var deferredReload: (() -> Void)?
    private var deferredPreferences: (() -> Void)?

    var isIdle: Bool {
        !hasCaptureLease && leaseWaiters.isEmpty && !hasDeferredMutations
    }

    var isInputEnabled: Bool {
        isIdle
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

    func settle() async {
        cancelActiveCapture()
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            settleWaiters.append(continuation)
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
        deferredReload != nil || deferredPreferences != nil
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
        deferredReload = nil
        deferredPreferences = nil
        reload?()
        preferences?()
    }

    private func resumeWaitersIfIdle() {
        guard isIdle else { return }
        let waiters = settleWaiters
        settleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let idleWaiters = Array(idleWaiters.values)
        self.idleWaiters.removeAll()
        idleWaiters.forEach { $0.resume() }
    }

    private func cancelIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
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
