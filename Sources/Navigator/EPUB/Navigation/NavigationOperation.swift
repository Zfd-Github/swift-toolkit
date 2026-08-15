//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// The terminal outcome of an internal reading-position mutation.
///
/// Public navigator APIs can map this to their legacy `Bool` contract, but the
/// navigation stack must preserve the precise outcome until that boundary.
enum NavigationResult {
    case applied
    case cancelled
    case timedOut
    case superseded
    case spreadNotLoaded
    case webContentTerminated
    case failed(Error)

    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var isSuperseded: Bool {
        if case .superseded = self { return true }
        return false
    }
}

/// Outcome of a navigation attempt which keeps the terminal result separate
/// from whether the visible reading position may already have changed.
enum NavigationMutationStage: Equatable {
    case preflight
    case linkResolution
    case targetLoad
    case pageViewMutation
    case paginationTransition
    case verification
    case locationCalculation
    case publication
    case stableLocationRestore
    case settleRecovery
}

struct NavigationMutationResult {
    let result: NavigationResult
    /// Whether a mutation was submitted or a visible transition was started.
    /// This is deliberately conservative: a rejected page view can still have
    /// changed scroll geometry before returning its failure.
    let mayHaveMutated: Bool
    /// Last published locator captured before mutation began.
    let stableLocator: Locator?
    /// True only after recovery synchronously proved `stableLocator` live.
    let stableVerified: Bool
    /// The stage which produced a non-applied result.
    let failureStage: NavigationMutationStage?

    init(
        result: NavigationResult,
        mayHaveMutated: Bool,
        stableLocator: Locator? = nil,
        stableVerified: Bool = false,
        failureStage: NavigationMutationStage? = nil
    ) {
        self.result = result
        self.mayHaveMutated = mayHaveMutated
        self.stableLocator = stableLocator
        self.stableVerified = stableVerified
        self.failureStage = failureStage
    }

    func preservingStableLocator(_ locator: Locator?) -> Self {
        .init(
            result: result,
            mayHaveMutated: mayHaveMutated,
            stableLocator: stableLocator ?? locator,
            stableVerified: stableVerified,
            failureStage: failureStage
        )
    }

    func verifiedStableLocation() -> Self {
        .init(
            result: result,
            mayHaveMutated: mayHaveMutated,
            stableLocator: stableLocator,
            stableVerified: true,
            failureStage: failureStage
        )
    }

    /// Changes only the terminal failure while retaining mutation and recovery
    /// evidence accumulated by inner layers.
    func replacingResult(
        _ result: NavigationResult,
        stableLocator fallbackStableLocator: Locator? = nil,
        failureStage: NavigationMutationStage
    ) -> Self {
        .init(
            result: result,
            mayHaveMutated: mayHaveMutated,
            stableLocator: stableLocator ?? fallbackStableLocator,
            stableVerified: stableVerified,
            failureStage: failureStage
        )
    }

    static func applied(
        mayHaveMutated: Bool,
        stableLocator: Locator? = nil
    ) -> Self {
        .init(
            result: .applied,
            mayHaveMutated: mayHaveMutated,
            stableLocator: stableLocator
        )
    }

    static func rejected(
        _ result: NavigationResult,
        mayHaveMutated: Bool,
        stableLocator: Locator? = nil,
        stage: NavigationMutationStage
    ) -> Self {
        .init(
            result: result,
            mayHaveMutated: mayHaveMutated,
            stableLocator: stableLocator,
            failureStage: stage
        )
    }
}

/// A navigation outcome carrying a value without weakening failure semantics.
enum NavigationValueResult<Value> {
    case applied(Value)
    case rejected(NavigationResult)

    var result: NavigationResult {
        switch self {
        case .applied:
            return .applied
        case let .rejected(result):
            return result
        }
    }
}

enum NavigationRelativeDirection: Equatable {
    case forward
    case backward
}

/// Describes queue coalescing. Payload is diagnostic only; mutation arguments
/// remain owned by the submitted operation closure.
enum NavigationOperationIntent: Equatable {
    case relative(NavigationRelativeDirection)
    case absolute(String)
    case reload(String)
    /// Recovery work which must retain its own queue entry. Unlike reloads,
    /// these requests are never coalesced with later work.
    case mustRunRecovery(String)

    fileprivate func queueCategory(
        operationID: UInt64
    ) -> NavigationOperationQueueCategory {
        switch self {
        case .relative:
            return .relative
        case .absolute:
            return .absolute
        case .reload:
            return .reload
        case .mustRunRecovery:
            return .mustRunRecovery(operationID)
        }
    }

    fileprivate var isMustRunRecovery: Bool {
        if case .mustRunRecovery = self {
            return true
        }
        return false
    }
}

private enum NavigationOperationQueueCategory: Hashable {
    case relative
    case absolute
    case reload
    case mustRunRecovery(UInt64)
}

/// Compatibility-safe duration used by the navigation executor.
///
/// `Clock`/`Duration` sleeping is not available on every deployment target
/// supported by the toolkit, so deadlines use monotonic uptime nanoseconds.
struct NavigationOperationTimeout {
    fileprivate let nanoseconds: UInt64

    static func seconds(_ value: UInt64) -> Self {
        Self(nanoseconds: value.multipliedReportingOverflow(by: 1_000_000_000).partialValue)
    }

    static func milliseconds(_ value: UInt64) -> Self {
        Self(nanoseconds: value.multipliedReportingOverflow(by: 1_000_000).partialValue)
    }
}

@MainActor
final class NavigationOperation: @unchecked Sendable {
    enum Phase {
        case queued
        case mutating
        case recovering
        case terminal
    }

    let operationID: UInt64
    let intent: NavigationOperationIntent
    private(set) var deadlineUptimeNanoseconds: UInt64

    private(set) var phase: Phase = .queued
    private(set) var paginationGeneration: UInt64?
    private(set) var spreadGeneration: UInt64?
    private(set) var cancellationResult: NavigationResult?
    private var recoveryCancellationResult: NavigationResult?
    private var terminalResult: NavigationResult?
    private var cancellationWaiters: [UUID: CheckedContinuation<NavigationResult, Never>] = [:]
    private var recoveryTaskCancellers: [UUID: () -> Void] = [:]

    init(
        operationID: UInt64,
        intent: NavigationOperationIntent,
        timeout: NavigationOperationTimeout
    ) {
        self.operationID = operationID
        self.intent = intent
        deadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(timeout.nanoseconds).partialValue
    }

    var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= activeDeadlineUptimeNanoseconds
    }

    var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = activeDeadlineUptimeNanoseconds
        return now < deadline
            ? deadline - now
            : 0
    }

    fileprivate var queueCategory: NavigationOperationQueueCategory {
        intent.queueCategory(operationID: operationID)
    }

    private var activeDeadlineUptimeNanoseconds: UInt64 {
        deadlineUptimeNanoseconds
    }

    func bindPaginationGeneration(_ generation: UInt64) {
        if paginationGeneration == nil {
            paginationGeneration = generation
        }
    }

    func bindSpreadGeneration(_ generation: UInt64) {
        spreadGeneration = generation
    }

    func beginMutation() -> NavigationResult? {
        if let cancellationResult {
            return cancellationResult
        }
        guard !isExpired else {
            return .timedOut
        }
        phase = .mutating
        return nil
    }

    /// Enters recovery without changing the operation's absolute deadline.
    /// Recovery may consume only the time left from the original submission.
    func beginRecovery() {
        guard terminalResult == nil, phase != .terminal else { return }
        phase = .recovering
    }

    /// Registers detached recovery work with the executor-owned operation so a
    /// deadline or owner cancellation can stop its Swift task as well.
    func registerRecoveryTask<Success>(_ task: Task<Success, Never>) -> UUID {
        let id = UUID()
        if terminalResult != nil
            || recoveryCancellationResult != nil
            || isExpired
            || phase == .terminal
        {
            task.cancel()
        } else {
            recoveryTaskCancellers[id] = { task.cancel() }
        }
        return id
    }

    func unregisterRecoveryTask(_ id: UUID) {
        recoveryTaskCancellers.removeValue(forKey: id)
    }

    func cancel(as result: NavigationResult = .cancelled) {
        guard phase != .terminal else { return }
        if phase == .recovering {
            cancelRecovery(as: result)
            return
        }
        guard cancellationResult == nil else { return }
        cancellationResult = result
        resumeCancellationWaiters(with: result)
    }

    /// Suspends until the executor cancels or expires this operation.
    ///
    /// Navigation waiters race their own completion against this signal so an
    /// active deadline can unwind a body without releasing its executor lease.
    func waitForCancellation() async -> NavigationResult {
        if let terminalResult { return terminalResult }
        if phase == .recovering {
            if let recoveryCancellationResult { return recoveryCancellationResult }
        } else if let cancellationResult {
            return cancellationResult
        }
        if isExpired { return .timedOut }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let terminalResult {
                    continuation.resume(returning: terminalResult)
                } else if phase == .recovering, let recoveryCancellationResult {
                    continuation.resume(returning: recoveryCancellationResult)
                } else if phase != .recovering, let cancellationResult {
                    continuation.resume(returning: cancellationResult)
                } else if isExpired {
                    continuation.resume(returning: .timedOut)
                } else {
                    cancellationWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCancellationWaiter(id)
            }
        }
    }

    func check(
        paginationGeneration currentPaginationGeneration: UInt64? = nil,
        spreadGeneration currentSpreadGeneration: UInt64? = nil
    ) -> NavigationResult? {
        if let terminalResult { return terminalResult }
        // Caller cancellation chooses the operation's terminal result, but an
        // already-mutated operation must still run its bounded recovery. A
        // hard owner teardown cancels the execution task separately.
        if phase == .recovering, let recoveryCancellationResult {
            return recoveryCancellationResult
        }
        if let cancellationResult, phase != .recovering {
            return cancellationResult
        }
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard !isExpired else {
            return .timedOut
        }
        if let expected = paginationGeneration,
           let currentPaginationGeneration,
           expected != currentPaginationGeneration
        {
            return .superseded
        }
        if let expected = spreadGeneration,
           let currentSpreadGeneration,
           expected != currentSpreadGeneration
        {
            return .superseded
        }
        return nil
    }

    @discardableResult
    fileprivate func finish(with proposedResult: NavigationResult) -> NavigationResult {
        if let terminalResult { return terminalResult }
        let result = recoveryCancellationResult
            ?? cancellationResult
            ?? proposedResult
        terminalResult = result
        phase = .terminal
        cancelRecoveryTasks()
        resumeCancellationWaiters(with: result)
        return result
    }

    private func cancelCancellationWaiter(_ id: UUID) {
        cancellationWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

    private func cancelRecovery(as result: NavigationResult) {
        guard recoveryCancellationResult == nil else { return }
        recoveryCancellationResult = result
        cancelRecoveryTasks()
        resumeCancellationWaiters(with: result)
    }

    private func cancelRecoveryTasks() {
        let cancellers = recoveryTaskCancellers.values
        recoveryTaskCancellers.removeAll()
        cancellers.forEach { $0() }
    }

    private func resumeCancellationWaiters(with result: NavigationResult) {
        let waiters = cancellationWaiters.values
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }
}

typealias NavigationOperationToken = NavigationOperation

/// Races an asynchronous wait against an executor-owned operation. Abandoning
/// a wait does not assume the underlying UIKit or WebKit work was cancelled;
/// callers use `onAbandon` to retire its generation or discard late results.
@MainActor
final class NavigationOperationWaiter<Value> {
    private var continuation: CheckedContinuation<NavigationValueResult<Value>, Never>?
    private var result: NavigationValueResult<Value>?
    private var workTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?

    func wait(
        operation: NavigationOperationToken,
        work: @escaping @MainActor () async -> Value,
        onAbandon: @escaping @MainActor (NavigationResult) -> Void = { _ in }
    ) async -> NavigationValueResult<Value> {
        if let result = operation.check() {
            onAbandon(result)
            return .rejected(result)
        }
        workTask = Task { @MainActor [weak self] in
            let value = await work()
            self?.finish(with: .applied(value))
        }
        cancellationTask = Task { @MainActor [weak self] in
            let result = await operation.waitForCancellation()
            guard self?.result == nil else { return }
            onAbandon(result)
            self?.finish(with: .rejected(result))
        }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    private func finish(with result: NavigationValueResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        workTask?.cancel()
        workTask = nil
        cancellationTask?.cancel()
        cancellationTask = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
final class NavigationOperationReservation: @unchecked Sendable {
    let operationID: UInt64
    private let waitForResult: @MainActor () async -> NavigationResult
    private let cancelRequest: @MainActor () -> Void

    fileprivate init(
        operationID: UInt64,
        waitForResult: @escaping @MainActor () async -> NavigationResult,
        cancelRequest: @escaping @MainActor () -> Void
    ) {
        self.operationID = operationID
        self.waitForResult = waitForResult
        self.cancelRequest = cancelRequest
    }

    fileprivate func wait() async -> NavigationResult {
        await waitForResult()
    }

    fileprivate func cancel() {
        cancelRequest()
    }
}

@MainActor
final class NavigationOperationExecutor {
    typealias OperationBody = @MainActor (NavigationOperation) async -> NavigationResult
    typealias IsolationHandler = @MainActor (
        NavigationOperation,
        NavigationResult
    ) -> Void

    private final class ResultWaiter {
        private var continuations: [CheckedContinuation<NavigationResult, Never>] = []
        private var terminalResult: NavigationResult?

        func wait() async -> NavigationResult {
            if let terminalResult {
                return terminalResult
            }
            return await withCheckedContinuation { continuation in
                if let terminalResult {
                    continuation.resume(returning: terminalResult)
                } else {
                    continuations.append(continuation)
                }
            }
        }

        @discardableResult
        func finish(_ result: NavigationResult) -> Bool {
            guard terminalResult == nil else { return false }
            terminalResult = result
            let waiters = continuations
            continuations.removeAll()
            waiters.forEach { $0.resume(returning: result) }
            return true
        }
    }

    private final class Request {
        let operation: NavigationOperation
        let body: OperationBody
        let completion: @MainActor (UInt64, NavigationResult) -> Void
        let waiter = ResultWaiter()
        var deadlineTask: Task<Void, Never>?
        var executionTask: Task<Void, Never>?

        init(
            operation: NavigationOperation,
            body: @escaping OperationBody,
            completion: @escaping @MainActor (UInt64, NavigationResult) -> Void
        ) {
            self.operation = operation
            self.body = body
            self.completion = completion
        }
    }

    private var nextOperationID: UInt64 = 0
    private var activeRequest: Request?
    private var pendingRequests: [NavigationOperationQueueCategory: Request] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let isolateAbandonedOperation: IsolationHandler
    private var shutdownResult: NavigationResult?

    init(isolateAbandonedOperation: @escaping IsolationHandler) {
        self.isolateAbandonedOperation = isolateAbandonedOperation
    }

    var activeOperationCountForTesting: Int {
        activeRequest == nil ? 0 : 1
    }

    var pendingOperationCountForTesting: Int {
        pendingRequests.count
    }

    var waiterCountForTesting: Int {
        activeOperationCountForTesting + pendingOperationCountForTesting
    }

    func submit(
        intent: NavigationOperationIntent,
        timeout: NavigationOperationTimeout,
        operation body: @escaping OperationBody
    ) async -> NavigationResult {
        let reservation = reserve(
            intent: intent,
            timeout: timeout,
            operation: body
        )
        return await wait(for: reservation)
    }

    /// Registers an operation synchronously in the current MainActor turn.
    /// Callers may reserve mandatory recovery before releasing an active lease,
    /// then await the result separately without an enqueue scheduling window.
    func reserve(
        intent: NavigationOperationIntent,
        timeout: NavigationOperationTimeout,
        registration: @escaping @MainActor (UInt64) -> Void = { _ in },
        completion: @escaping @MainActor (UInt64, NavigationResult) -> Void = { _, _ in },
        operation body: @escaping OperationBody
    ) -> NavigationOperationReservation {
        nextOperationID &+= 1
        let request = Request(
            operation: NavigationOperation(
                operationID: nextOperationID,
                intent: intent,
                timeout: timeout
            ),
            body: body,
            completion: completion
        )
        registration(request.operation.operationID)
        let reservation = NavigationOperationReservation(
            operationID: request.operation.operationID,
            waitForResult: {
                await request.waiter.wait()
            },
            cancelRequest: { [weak self, weak request] in
                guard let self, let request else { return }
                self.cancel(request)
            }
        )
        if let shutdownResult {
            finishPending(request, with: shutdownResult)
        } else {
            enqueue(request)
        }
        return reservation
    }

    func wait(
        for reservation: NavigationOperationReservation
    ) async -> NavigationResult {
        await withTaskCancellationHandler {
            await reservation.wait()
        } onCancel: {
            Task { @MainActor [weak reservation] in
                reservation?.cancel()
            }
        }
    }

    /// Cancels queued work, while leaving an already-submitted WebKit mutation
    /// under executor ownership until its recovery reaches a terminal state.
    func supersedePendingOperations() {
        for request in pendingRequests.values {
            finishPending(request, with: .superseded)
        }
        pendingRequests.removeAll()
    }

    func cancelActiveOperation() {
        activeRequest?.operation.cancel()
    }

    func abortActiveOperation() {
        guard let request = activeRequest else { return }
        request.operation.cancel()
        request.executionTask?.cancel()
        isolateAbandonedOperation(request.operation, .cancelled)
        finishActive(request, with: .cancelled)
    }

    /// Permanently retires the executor. Pending bodies are never started;
    /// every request still completes through its normal callback so owners can
    /// release reservation state and waiters exactly once.
    func shutdown(with result: NavigationResult = .cancelled) {
        guard shutdownResult == nil else { return }
        shutdownResult = result

        let pending = pendingRequests.values.sorted {
            $0.operation.operationID < $1.operation.operationID
        }
        pendingRequests.removeAll()
        pending.forEach { finishPending($0, with: result) }

        if let request = activeRequest {
            request.operation.cancel(as: result)
            request.executionTask?.cancel()
            isolateAbandonedOperation(request.operation, result)
            finishActive(request, with: result)
        } else {
            resumeIdleWaitersIfNeeded()
        }
    }

    func waitUntilIdle() async {
        guard activeRequest != nil || !pendingRequests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if activeRequest == nil, pendingRequests.isEmpty {
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
            }
        }
    }

    private func enqueue(_ request: Request) {
        guard activeRequest != nil else {
            start(request)
            return
        }

        let category = request.operation.queueCategory
        if let replaced = pendingRequests.updateValue(request, forKey: category) {
            finishPending(replaced, with: .superseded)
        }
        scheduleQueuedDeadline(for: request)
    }

    private func scheduleQueuedDeadline(for request: Request) {
        let operationID = request.operation.operationID
        let delay = request.operation.remainingNanoseconds
        request.deadlineTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.expireQueuedOperation(operationID)
        }
    }

    private func expireQueuedOperation(_ operationID: UInt64) {
        guard let entry = pendingRequests.first(where: {
            $0.value.operation.operationID == operationID
        }) else {
            return
        }
        pendingRequests.removeValue(forKey: entry.key)
        finishPending(entry.value, with: .timedOut)
    }

    private func start(_ request: Request) {
        request.deadlineTask?.cancel()
        request.deadlineTask = nil

        if let result = request.operation.beginMutation() {
            finishPending(request, with: result)
            startNextPendingOperation()
            return
        }

        activeRequest = request
        scheduleActiveDeadline(for: request)
        request.executionTask = Task { @MainActor [weak self, weak request] in
            guard let self, let request else { return }
            let result = await request.body(request.operation)
            self.finishActive(request, with: result)
        }
    }

    private func finishActive(_ request: Request, with result: NavigationResult) {
        guard activeRequest === request else { return }
        request.deadlineTask?.cancel()
        request.deadlineTask = nil
        request.executionTask = nil
        let terminalResult = request.operation.finish(with: result)
        activeRequest = nil
        request.waiter.finish(terminalResult)
        request.completion(request.operation.operationID, terminalResult)
        startNextPendingOperation()
    }

    private func finishPending(_ request: Request, with result: NavigationResult) {
        request.deadlineTask?.cancel()
        request.deadlineTask = nil
        let terminalResult = request.operation.finish(with: result)
        request.waiter.finish(terminalResult)
        request.completion(request.operation.operationID, terminalResult)
    }

    private func cancel(_ request: Request) {
        if activeRequest === request {
            request.operation.cancel()
            request.executionTask?.cancel()
            return
        }
        guard let entry = pendingRequests.first(where: { $0.value === request }) else {
            return
        }
        pendingRequests.removeValue(forKey: entry.key)
        finishPending(request, with: .cancelled)
    }

    private func scheduleActiveDeadline(for request: Request) {
        let operationID = request.operation.operationID
        let delay = request.operation.remainingNanoseconds
        request.deadlineTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.expireActiveOperation(operationID)
        }
    }

    private func expireActiveOperation(_ operationID: UInt64) {
        guard
            let request = activeRequest,
            request.operation.operationID == operationID
        else {
            return
        }
        request.operation.cancel(as: .timedOut)
        request.executionTask?.cancel()
        // Swift task cancellation is cooperative. The body may be suspended in
        // WebKit/UIKit code which never resumes its continuation, so the
        // deadline itself must retire the lease. Isolation runs synchronously
        // first, ensuring a late body can mutate only the detached generation.
        isolateAbandonedOperation(request.operation, .timedOut)
        finishActive(request, with: .timedOut)
    }

    private func startNextPendingOperation() {
        guard activeRequest == nil else { return }
        guard shutdownResult == nil else {
            resumeIdleWaitersIfNeeded()
            return
        }
        guard let next = pendingRequests.values.min(by: {
            let lhsIsRecovery = $0.operation.intent.isMustRunRecovery
            let rhsIsRecovery = $1.operation.intent.isMustRunRecovery
            if lhsIsRecovery != rhsIsRecovery {
                return lhsIsRecovery
            }
            return $0.operation.operationID < $1.operation.operationID
        }) else {
            resumeIdleWaitersIfNeeded()
            return
        }
        pendingRequests.removeValue(forKey: next.operation.queueCategory)
        start(next)
    }

    private func resumeIdleWaitersIfNeeded() {
        guard activeRequest == nil, pendingRequests.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
