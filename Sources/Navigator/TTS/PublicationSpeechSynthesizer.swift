//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared

public protocol PublicationSpeechSynthesizerDelegate: AnyObject {
    /// Called when the synthesizer's state is updated.
    @MainActor
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange state: PublicationSpeechSynthesizer.State)

    /// Called when an `error` occurs while speaking `utterance`.
    @MainActor
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error)
}

/// `PublicationSpeechSynthesizer` orchestrates the rendition of a `Publication` by iterating through its content,
/// splitting it into individual utterances using a `ContentTokenizer`, then using a `TTSEngine` to read them aloud.
@preconcurrency @MainActor
public class PublicationSpeechSynthesizer: Loggable {
    public typealias EngineFactory = () -> TTSEngine
    public typealias TokenizerFactory = (_ defaultLanguage: Language?) -> ContentTokenizer

    /// Returns whether the `publication` can be played with a `PublicationSpeechSynthesizer`.
    nonisolated public static func canSpeak(publication: Publication) -> Bool {
        publication.content() != nil
    }

    public enum Error: Swift.Error {
        /// Underlying `TTSEngine` error.
        case engine(TTSError)
    }

    /// User configuration for the text-to-speech engine.
    public struct Configuration: Equatable {
        /// Language overriding the publication one.
        public var defaultLanguage: Language?

        /// Identifier for the voice used to speak the utterances.
        public var voiceIdentifier: String?

        public init(
            defaultLanguage: Language? = nil,
            voiceIdentifier: String? = nil
        ) {
            self.defaultLanguage = defaultLanguage
            self.voiceIdentifier = voiceIdentifier
        }
    }

    /// An utterance is an arbitrary text (e.g. sentence) extracted from the publication, that can be synthesized by
    /// the TTS engine.
    public struct Utterance: Equatable {
        /// Text to be spoken.
        public let text: String
        /// Locator to the utterance in the publication.
        public let locator: Locator
        /// Language of this utterance, if it dffers from the default publication language.
        public let language: Language?
        let prefetchIdentifier = UUID()

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text == rhs.text &&
                lhs.locator == rhs.locator &&
                lhs.language == rhs.language
        }
    }

    /// Represents a state of the `PublicationSpeechSynthesizer`.
    public enum State: Equatable {
        /// The synthesizer is completely stopped and must be (re)started from a given locator.
        case stopped

        /// The synthesizer is paused at the given utterance.
        case paused(Utterance)

        /// The TTS engine is synthesizing the associated utterance.
        /// `range` will be regularly updated while the utterance is being played.
        case playing(Utterance, range: Locator?)

        var isPlaying: Bool {
            switch self {
            case .stopped, .paused:
                return false
            case .playing:
                return true
            }
        }
    }

    /// Current state of the `PublicationSpeechSynthesizer`.
    public private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            if oldValue.isPlaying != state.isPlaying {
                audioSession.user(audioSessionUser, didChangePlaying: state.isPlaying)
            }
            delegate?.publicationSpeechSynthesizer(self, stateDidChange: state)
        }
    }

    /// Current configuration of the `PublicationSpeechSynthesizer`.
    ///
    /// Changes are not immediate, they will be applied for the next utterance.
    public var config: Configuration {
        didSet {
            guard oldValue != config else { return }
            invalidatePrefetch()
            iteratorLedger.invalidateForwardGroups()
        }
    }

    public weak var delegate: PublicationSpeechSynthesizerDelegate?

    private let publication: Publication
    private let audioSession: AudioSessionManaging
    private let engineFactory: EngineFactory
    private let tokenizerFactory: TokenizerFactory
    private static let maximumPrefetchDuration: TimeInterval = 15
    private static let maximumSingleUtterancePrefetchDuration: TimeInterval = 75

    /// Creates a `PublicationSpeechSynthesizer` using the given `TTSEngine` factory.
    ///
    /// Returns null if the publication cannot be synthesized.
    ///
    /// - Parameters:
    ///   - publication: Publication which will be iterated through and synthesized.
    ///   - config: Initial TTS configuration.
    ///   - audioSessionConfig: Configuration of the audio session used to play
    ///     the utterances.
    ///   - audioSession: Audio session manager used to coordinate playback.
    ///   - engineFactory: Factory to create an instance of `TtsEngine`. Defaults to `AVTTSEngine`.
    ///   - tokenizerFactory: Factory to create a `ContentTokenizer` which will be used to
    ///     split each `ContentElement` item into smaller chunks. Splits by sentences by default.
    ///   - delegate: Optional delegate.
    public init?(
        publication: Publication,
        config: Configuration = Configuration(),
        audioSessionConfig: AudioSession.Configuration = .init(
            category: .playback,
            mode: .spokenAudio,
            routeSharingPolicy: .longFormAudio
        ),
        audioSession: AudioSessionManaging = AudioSession.shared,
        engineFactory: @escaping EngineFactory = { AVTTSEngine() },
        tokenizerFactory: @escaping TokenizerFactory = defaultTokenizerFactory,
        delegate: PublicationSpeechSynthesizerDelegate? = nil
    ) {
        guard Self.canSpeak(publication: publication) else {
            return nil
        }

        self.publication = publication
        self.config = config
        self.audioSession = audioSession
        audioSessionUser = AudioSessionUser(config: audioSessionConfig)
        self.engineFactory = engineFactory
        self.tokenizerFactory = tokenizerFactory
        self.delegate = delegate
    }

    deinit {
        audioSession.end(for: audioSessionUser)
        // Cancel playback + look-ahead even if task bodies only weakly reference
        // `self` and are suspended (speak / iterator.next / waiter).
        //
        // Waiters live in an independent registry so deinit can resume them even
        // when Task.cancel does not complete a withCheckedContinuation.
        playbackOperation?.lifecycle.cancelTask()
        forwardPrefetchOperation?.waiters.resumeAll()
        readyForwardPrefetchOperation?.waiters.resumeAll()
        for operation in retiredForwardPrefetchOperations.values {
            operation.waiters.resumeAll()
            operation.task.cancel()
            operation.cancellationTask?.cancel()
        }
        forwardPrefetchLifecycle.cancelTask()
        if let engine = engineStorage as? TTSPrefetchingEngine {
            Task { @MainActor in
                engine.cancelPrefetch()
            }
        }
    }

    /// The default content tokenizer will split the `Content.Element` items into individual sentences.
    nonisolated public static let defaultTokenizerFactory: TokenizerFactory = { defaultLanguage in
        makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .sentence, language: language)
            }
        )
    }

    // MARK: - Playback / prefetch state machine
    //
    // Invariants (review every entry point against these — do not update fields ad hoc):
    //
    // 1. Playback operation: identified by `operationGeneration` and owned by
    //    `playbackOperation`, including the initial `.preparing` phase and the
    //    matching prepared cache. Task bodies must not strongly retain self
    //    across speak / wait / iterator / cancel-drain suspensions.
    // 2. Forward-prefetch operation: identified by `(prefetchGeneration, taskID)`
    //    and owned by the active/ready/retired `ForwardPrefetchOperation` slots.
    //    Its task, ready queue, waiter registry, and cancellation drain move
    //    together. Invalidation resumes the detached waiters immediately and a
    //    successor retains the latest retired drain before doing engine work.
    // 3. Iterator accounting: `iteratorLedger` is the only owner of iterator
    //    position, pending fetched content, forward placeholders, and rollback.
    //    Every non-nil movement is recorded with a UUID before generation checks.
    //    Transition table:
    //      - fetched -> undoing before awaiting an opposite movement;
    //      - a non-nil opposite result clears undo before generation validation;
    //      - rollbackRequired(n) decrements after every non-nil reverse movement,
    //        before generation validation;
    //      - an empty token result transfers its placeholder advances exactly once
    //        to the next placeholder or the trailing count;
    //      - token error, supersession, or retry exhaustion restores the same
    //        prepared placeholder to pending state.
    // 4. Unified tokenizer commit: after any user tokenizer call, re-check the
    //    immutable operation token's playback/forward identity, iterator,
    //    movement, and stable ledger destination before writing `utterances` or
    //    placeholders. Locator trim (`applyingStartTextIfNeeded`) is applied once
    //    per content block and must not re-run on config-only retries.
    // 5. Waiters: each forward operation owns a `ContinuationRegistry`; invalidate
    //    and deinit always resume the detached operation's registry.

    private enum PlaybackPhase {
        case preparing(startLocator: Locator?)
        case playing
    }

    private struct PlaybackOperation {
        let generation: UInt64
        let phase: PlaybackPhase
        let task: Task<Void, Never>
        let preparationResult: InitialPrefetchResult?
        let lifecycle: DetachedTaskLifecycleHandle
    }

    private struct InitialPrefetchRequest {
        let engine: TTSPrefetchingEngine
        let utterance: TTSUtterance
    }

    private struct ForwardPrefetchOperation {
        let generation: UInt64
        let taskID: UInt64
        let task: Task<Void, Never>
        var ready: [ForwardPrefetch]
        let waiters: ContinuationRegistry
        var cancellationTask: Task<Void, Never>?
    }

    private struct OperationToken {
        let playbackGeneration: UInt64
        let prefetchGeneration: UInt64
        let forwardTaskID: UInt64?
        let iterator: ContentIterator
        let movementID: UUID
        let destination: TokenizationDestination
        let raw: ContentElement
        let prepared: ContentElement
    }

    private enum TokenizationDestination {
        case playbackMovement(direction: Direction)
        case playbackGroup(id: UUID)
        case forwardGroup(id: UUID)
        case forwardCandidate(id: UUID)
    }

    private enum TokenizationSource {
        case bufferedPlayback
        case iteratorPlayback
        case forwardGroupLoader
        case forwardCandidateCollection

        var isForwardOperation: Bool {
            switch self {
            case .bufferedPlayback, .iteratorPlayback:
                return false
            case .forwardGroupLoader, .forwardCandidateCollection:
                return true
            }
        }
    }

    private enum TokenCommitResult {
        case committed([Utterance])
        case retryWithNewConfig
        case superseded
    }

    private enum IteratorState {
        case synchronized
        case fetched(
            movementID: UUID,
            direction: Direction,
            raw: ContentElement,
            prepared: ContentElement
        )
        case undoing(movementID: UUID, originalDirection: Direction, prepared: ContentElement)
        case rollbackRequired(count: Int)
    }

    private struct IteratorLedger {
        enum LiveStep {
            case ready(FetchedMovement)
            case fetch
            case opposite(UndoMovement)
            case unavailable
        }

        enum ForwardStep {
            case placeholder(GroupLease)
            case fetch
            case unavailable
        }

        struct FetchedMovement {
            let movementID: UUID
            let direction: Direction
            let raw: ContentElement
            let prepared: ContentElement
        }

        struct UndoMovement {
            let movementID: UUID
            let originalDirection: Direction
            let raw: ContentElement
            let prepared: ContentElement
        }

        struct GroupLease {
            let groupID: UUID
            let movementID: UUID
            let raw: ContentElement
            let prepared: ContentElement
            let utterances: [Utterance]?
        }

        private(set) var iterator: ContentIterator?
        private(set) var state: IteratorState = .synchronized
        private var forwardGroups: [BufferedUtteranceGroup] = []
        private var trailingForwardAdvanceCount = 0

        mutating func reset(iterator: ContentIterator?) {
            self.iterator = iterator
            state = .synchronized
            forwardGroups = []
            trailingForwardAdvanceCount = 0
        }

        func owns(_ iterator: ContentIterator) -> Bool {
            self.iterator === iterator
        }

        mutating func invalidateForwardGroups() {
            for index in forwardGroups.indices {
                forwardGroups[index].utterances = nil
            }
        }

        mutating func recordFetched(
            movementID: UUID,
            direction: Direction,
            raw: ContentElement,
            prepared: ContentElement
        ) {
            state = .fetched(
                movementID: movementID,
                direction: direction,
                raw: raw,
                prepared: prepared
            )
        }

        mutating func beginLiveStep(direction: Direction) -> LiveStep {
            switch state {
            case let .fetched(movementID, fetchedDirection, raw, prepared):
                let movement = FetchedMovement(
                    movementID: movementID,
                    direction: fetchedDirection,
                    raw: raw,
                    prepared: prepared
                )
                if fetchedDirection == direction {
                    return .ready(movement)
                }
                state = .undoing(
                    movementID: movementID,
                    originalDirection: fetchedDirection,
                    prepared: prepared
                )
                return .opposite(UndoMovement(
                    movementID: movementID,
                    originalDirection: fetchedDirection,
                    raw: raw,
                    prepared: prepared
                ))

            case .synchronized:
                return .fetch

            case .undoing, .rollbackRequired:
                return .unavailable
            }
        }

        mutating func beginForwardStep() -> ForwardStep {
            switch state {
            case let .fetched(movementID, direction, _, _) where direction == .forward:
                guard let placeholder = createForwardPlaceholder(movementID: movementID) else {
                    return .unavailable
                }
                return .placeholder(placeholder)

            case .synchronized:
                return .fetch

            case .fetched, .undoing, .rollbackRequired:
                return .unavailable
            }
        }

        mutating func beginFetchedUndoForRollback() -> UndoMovement? {
            guard case let .fetched(movementID, direction, raw, prepared) = state,
                  direction == .forward
            else {
                return nil
            }
            state = .undoing(
                movementID: movementID,
                originalDirection: direction,
                prepared: prepared
            )
            return UndoMovement(
                movementID: movementID,
                originalDirection: direction,
                raw: raw,
                prepared: prepared
            )
        }

        mutating func restoreUndo(_ movement: UndoMovement) {
            guard case let .undoing(movementID, _, _) = state,
                  movementID == movement.movementID
            else {
                return
            }
            recordFetched(
                movementID: movement.movementID,
                direction: movement.originalDirection,
                raw: movement.raw,
                prepared: movement.prepared
            )
        }

        mutating func completeUndo(movementID: UUID) {
            guard case let .undoing(currentID, _, _) = state,
                  currentID == movementID
            else {
                return
            }
            state = .synchronized
        }

        mutating func completeFetched(movementID: UUID, direction: Direction) -> Bool {
            guard case let .fetched(currentID, _, _, _) = state,
                  currentID == movementID
            else {
                return false
            }
            state = .synchronized
            if direction == .forward {
                trailingForwardAdvanceCount = 0
            }
            return true
        }

        @discardableResult
        mutating func createForwardPlaceholder(movementID: UUID) -> GroupLease? {
            guard case let .fetched(currentID, direction, raw, prepared) = state,
                  currentID == movementID,
                  direction == .forward
            else {
                return nil
            }
            let group = BufferedUtteranceGroup(
                groupID: UUID(),
                movementID: movementID,
                raw: raw,
                prepared: prepared,
                utterances: nil,
                iteratorAdvanceCount: trailingForwardAdvanceCount + 1,
                isLeased: true
            )
            trailingForwardAdvanceCount = 0
            forwardGroups.append(group)
            state = .synchronized
            return GroupLease(
                groupID: group.groupID,
                movementID: group.movementID,
                raw: raw,
                prepared: prepared,
                utterances: nil
            )
        }

        var hasForwardGroups: Bool {
            !forwardGroups.isEmpty
        }

        mutating func leaseFirstForwardGroup() -> GroupLease? {
            guard !forwardGroups.isEmpty, !forwardGroups[0].isLeased else {
                return nil
            }
            forwardGroups[0].isLeased = true
            return lease(forwardGroups[0])
        }

        mutating func leaseForwardGroup(groupID: UUID) -> GroupLease? {
            guard let index = forwardGroups.firstIndex(where: { $0.groupID == groupID }),
                  !forwardGroups[index].isLeased
            else {
                return nil
            }
            forwardGroups[index].isLeased = true
            return lease(forwardGroups[index])
        }

        func forwardGroupIDs() -> [UUID] {
            forwardGroups.map(\.groupID)
        }

        func forwardGroup(groupID: UUID) -> GroupLease? {
            forwardGroups.first(where: { $0.groupID == groupID }).map(lease)
        }

        func matchesFetched(
            movementID: UUID,
            direction: Direction,
            raw: ContentElement,
            prepared: ContentElement
        ) -> Bool {
            guard case let .fetched(currentID, currentDirection, currentRaw, currentPrepared) = state else {
                return false
            }
            return currentID == movementID &&
                currentDirection == direction &&
                currentRaw.isEqualTo(raw) &&
                currentPrepared.isEqualTo(prepared)
        }

        func matchesForwardGroup(
            groupID: UUID,
            movementID: UUID,
            raw: ContentElement,
            prepared: ContentElement
        ) -> Bool {
            guard let group = forwardGroups.first(where: { $0.groupID == groupID }) else {
                return false
            }
            return group.movementID == movementID &&
                group.isLeased &&
                group.utterances == nil &&
                group.raw.isEqualTo(raw) &&
                group.prepared.isEqualTo(prepared)
        }

        mutating func restoreForwardGroup(groupID: UUID) {
            guard let index = forwardGroups.firstIndex(where: { $0.groupID == groupID }) else {
                return
            }
            forwardGroups[index].isLeased = false
        }

        mutating func fillForwardPlaceholder(
            groupID: UUID,
            utterances: [Utterance]
        ) -> Bool {
            guard let index = forwardGroups.firstIndex(where: { $0.groupID == groupID }),
                  forwardGroups[index].isLeased
            else {
                return false
            }
            if utterances.isEmpty {
                mergeEmptyForwardGroup(at: index)
                return true
            }
            forwardGroups[index].utterances = utterances
            forwardGroups[index].isLeased = false
            return true
        }

        mutating func consumeForwardGroup(
            groupID: UUID,
            utterances: [Utterance]
        ) -> Bool {
            guard let index = forwardGroups.firstIndex(where: { $0.groupID == groupID }),
                  forwardGroups[index].isLeased
            else {
                return false
            }
            if utterances.isEmpty {
                mergeEmptyForwardGroup(at: index)
            } else {
                forwardGroups.remove(at: index)
            }
            return true
        }

        mutating func beginRollback() -> (iterator: ContentIterator, count: Int)? {
            guard let iterator else { return nil }
            switch state {
            case .synchronized, .rollbackRequired:
                break
            case .fetched, .undoing:
                return nil
            }
            let bufferedCount = forwardGroups.reduce(trailingForwardAdvanceCount) {
                $0 + $1.iteratorAdvanceCount
            }
            let interruptedCount: Int
            if case let .rollbackRequired(count) = state {
                interruptedCount = count
            } else {
                interruptedCount = 0
            }
            let count = bufferedCount + interruptedCount
            forwardGroups = []
            trailingForwardAdvanceCount = 0
            if count > 0 {
                state = .rollbackRequired(count: count)
            } else if case .rollbackRequired = state {
                state = .synchronized
            }
            return (iterator, count)
        }

        var requiresRollback: Bool {
            if case let .rollbackRequired(count) = state {
                return count > 0
            }
            return false
        }

        mutating func completeRollbackMovement() {
            guard case let .rollbackRequired(count) = state else { return }
            state = count > 1 ? .rollbackRequired(count: count - 1) : .synchronized
        }

        private func lease(_ group: BufferedUtteranceGroup) -> GroupLease {
            GroupLease(
                groupID: group.groupID,
                movementID: group.movementID,
                raw: group.raw,
                prepared: group.prepared,
                utterances: group.utterances
            )
        }

        private mutating func mergeEmptyForwardGroup(at index: Int) {
            let advanceCount = forwardGroups.remove(at: index).iteratorAdvanceCount
            if forwardGroups.indices.contains(index) {
                forwardGroups[index].iteratorAdvanceCount += advanceCount
            } else {
                trailingForwardAdvanceCount += advanceCount
            }
        }
    }

    private var playbackOperation: PlaybackOperation?
    private var forwardPrefetchOperation: ForwardPrefetchOperation?
    /// A normally completed operation stays here only while prepared items remain.
    private var readyForwardPrefetchOperation: ForwardPrefetchOperation?
    /// Cancelled operations remain reachable until their owned drain completes.
    private var retiredForwardPrefetchOperations: [UInt64: ForwardPrefetchOperation] = [:]
    private var nextForwardPrefetchTaskID: UInt64 = 0
    /// Cancels the active look-ahead task from `deinit` without a MainActor hop.
    private let forwardPrefetchLifecycle = DetachedTaskLifecycleHandle()
    private var operationGeneration: UInt64 = 0
    private var prefetchGeneration: UInt64 = 0
    private struct ForwardPrefetch {
        let identifier: UUID
        let duration: TimeInterval
    }

    private var engineStorage: TTSEngine?

    /// Whether `play` is suspended waiting for the next look-ahead item (or
    /// look-ahead end). Used by tests instead of fixed `Task.sleep` delays.
    var isWaitingForForwardPrefetchForTesting: Bool {
        forwardPrefetchOperation?.waiters.hasWaiters == true ||
            retiredForwardPrefetchOperations.values.contains { $0.waiters.hasWaiters }
    }

    private var engine: TTSEngine {
        if let engineStorage {
            return engineStorage
        }
        let engine = engineFactory()
        engineStorage = engine
        return engine
    }

    /// List of synthesizer voices supported by the TTS engine.
    public var availableVoices: [TTSVoice] {
        engine.availableVoices
    }

    /// Switches the voice for the current utterance from its latest word boundary.
    @discardableResult
    public func switchVoice(to identifier: String?) -> Bool {
        guard engine.switchVoice(to: identifier) else {
            return false
        }
        config.voiceIdentifier = identifier
        return true
    }

    /// Returns the first voice with the given `identifier` supported by the TTS `engine`.
    ///
    /// This can be used to restore the user selected voice after storing it in the user defaults.
    public func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        let voice = lastUsedVoice.takeIf { $0.identifier == identifier }
            ?? engine.voiceWithIdentifier(identifier)

        lastUsedVoice = voice
        return voice
    }

    /// Cache for the last requested voice, for performance.
    private var lastUsedVoice: TTSVoice?

    /// Prepares the first utterance at `startLocator` without scheduling audio.
    ///
    /// Returns as soon as the first utterance is ready. Forward look-ahead may
    /// continue in the background up to `maximumPrefetchDuration` and does not
    /// block this call — offline engines (e.g. on-device neural TTS) would
    /// otherwise delay first audio by generating many seconds of speech first.
    ///
    /// Returns whether the first utterance was prepared successfully. Returns
    /// `false` when playback is active, no utterance is available, the request
    /// is cancelled or superseded, the engine doesn't support prefetching, or
    /// it rejects the prepared audio.
    @discardableResult
    public func prefetch(from startLocator: Locator? = nil) async -> Bool {
        guard case .stopped = state else {
            return false
        }
        let oldPlaybackTask = cancelPlaybackTask()
        let oldPrefetchTask = invalidatePrefetch()
        operationGeneration &+= 1
        let generation = operationGeneration
        let prefetchGeneration = self.prefetchGeneration
        setStartText(from: startLocator)
        resetIterator(nil)
        let weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
        let result = InitialPrefetchResult()
        let task = Task {
            let didPrefetch = await Self.prefetchInitial(
                weakSynthesizer: weakSynthesizer,
                from: startLocator,
                oldPlaybackTask: oldPlaybackTask,
                oldPrefetchTask: oldPrefetchTask,
                operationGeneration: generation,
                prefetchGeneration: prefetchGeneration
            )
            result.finish(didPrefetch)
        }
        setPlaybackOperation(
            generation: generation,
            phase: .preparing(startLocator: startLocator),
            task: task,
            preparationResult: result
        )
        return await withTaskCancellationHandler(
            operation: {
                await result.value()
            },
            onCancel: {
                task.cancel()
                result.finish(false)
                Task { @MainActor in
                    weakSynthesizer.value?.cancelInitialPrefetchIfCurrent(
                        operationGeneration: generation,
                        startLocator: startLocator,
                        prefetchGeneration: prefetchGeneration
                    )
                }
            }
        )
    }

    private static func prefetchInitial(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        from startLocator: Locator?,
        oldPlaybackTask: Task<Void, Never>?,
        oldPrefetchTask: Task<Void, Never>?,
        operationGeneration generation: UInt64,
        prefetchGeneration: UInt64
    ) async -> Bool {
        await oldPlaybackTask?.value
        await oldPrefetchTask?.value
        guard !Task.isCancelled else { return false }
        guard weakSynthesizer.value?.beginInitialPrefetch(
            from: startLocator,
            operationGeneration: generation,
            prefetchGeneration: prefetchGeneration
        ) == true else {
            return false
        }
        guard let utterance = await Self.nextUtterance(
            weakSynthesizer: weakSynthesizer,
            direction: .forward,
            generation: generation
        ) else { return false }
        guard !Task.isCancelled else { return false }
        guard let request = weakSynthesizer.value?.initialPrefetchRequest(
            for: utterance,
            from: startLocator,
            operationGeneration: generation,
            prefetchGeneration: prefetchGeneration
        ) else {
            return false
        }
        guard let prefetchDuration = await request.engine.prefetch(
            request.utterance,
            maximumDuration: Self.maximumSingleUtterancePrefetchDuration
        ),
        prefetchDuration.isFinite,
        prefetchDuration > 0,
        prefetchDuration <= Self.maximumSingleUtterancePrefetchDuration
        else { return false }
        guard !Task.isCancelled else { return false }
        return weakSynthesizer.value?.commitInitialPrefetch(
            utterance,
            from: startLocator,
            operationGeneration: generation,
            prefetchGeneration: prefetchGeneration
        ) == true
    }

    private func beginInitialPrefetch(
        from startLocator: Locator?,
        operationGeneration generation: UInt64,
        prefetchGeneration: UInt64
    ) -> Bool {
        guard
            isCurrentPreparation(generation: generation, startLocator: startLocator),
            prefetchGeneration == self.prefetchGeneration
        else {
            return false
        }
        resetIterator(publication.content(from: startLocator)?.iterator())
        return true
    }

    private func initialPrefetchRequest(
        for utterance: Utterance,
        from startLocator: Locator?,
        operationGeneration generation: UInt64,
        prefetchGeneration: UInt64
    ) -> InitialPrefetchRequest? {
        guard
            isCurrentPreparation(generation: generation, startLocator: startLocator),
            prefetchGeneration == self.prefetchGeneration,
            let engine = engine as? TTSPrefetchingEngine
        else {
            return nil
        }
        return InitialPrefetchRequest(
            engine: engine,
            utterance: ttsUtterance(for: utterance)
        )
    }

    private func commitInitialPrefetch(
        _ utterance: Utterance,
        from startLocator: Locator?,
        operationGeneration generation: UInt64,
        prefetchGeneration: UInt64
    ) -> Bool {
        guard
            isCurrentPreparation(generation: generation, startLocator: startLocator),
            prefetchGeneration == self.prefetchGeneration
        else {
            return false
        }
        preparedStartLocator = startLocator
        preparedUtterance = utterance

        // Fire-and-forget: do not await the forward waterline here. Callers
        // (e.g. app audio owner) await `prefetch` then immediately `start`;
        // blocking on ~15s of look-ahead audio makes first playback hang.
        startForwardPrefetch(
            generation: generation,
            prefetchGeneration: prefetchGeneration
        )
        return true
    }

    /// (Re)starts the synthesizer from the given locator or the beginning of the publication.
    public func start(from startLocator: Locator? = nil) {
        audioSession.start(with: audioSessionUser, isPlaying: false)

        let oldPlaybackTask = cancelPlaybackTask()
        if
            let operation = playbackOperation,
            isCurrentPreparation(generation: operation.generation, startLocator: startLocator),
            preparedStartLocator == startLocator,
            let utterance = preparedUtterance
        {
            preparedStartLocator = nil
            preparedUtterance = nil
            let generation = operation.generation
            let task = Task { [weak self] in
                await oldPlaybackTask?.value
                // Bind `self` only in a nested scope so it is not retained across
                // `continuePlaying` (speak / look-ahead waits).
                let weakSynthesizer: WeakPublicationSpeechSynthesizer
                if let self {
                    guard generation == self.operationGeneration else { return }
                    weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
                } else {
                    return
                }
                await Self.continuePlaying(
                    weakSynthesizer: weakSynthesizer,
                    utterance: utterance,
                    generation: generation
                )
            }
            setPlaybackOperation(generation: generation, phase: .playing, task: task)
            return
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        setStartText(from: startLocator)
        resetIterator(nil)
        let task = Task { [weak self] in
            await oldPlaybackTask?.value
            await oldPrefetchTask?.value
            let weakSynthesizer: WeakPublicationSpeechSynthesizer
            if let self {
                guard generation == self.operationGeneration else { return }
                self.resetIterator(self.publication.content(from: startLocator)?.iterator())
                weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
            } else {
                return
            }
            await Self.continuePlaying(
                weakSynthesizer: weakSynthesizer,
                utterance: nil,
                generation: generation
            )
        }
        setPlaybackOperation(generation: generation, phase: .playing, task: task)
    }

    private func setPlaybackOperation(
        generation: UInt64,
        phase: PlaybackPhase,
        task: Task<Void, Never>,
        preparationResult: InitialPrefetchResult? = nil
    ) {
        let lifecycle = DetachedTaskLifecycleHandle()
        lifecycle.setTask(task)
        playbackOperation = PlaybackOperation(
            generation: generation,
            phase: phase,
            task: task,
            preparationResult: preparationResult,
            lifecycle: lifecycle
        )
    }

    @discardableResult
    private func cancelPlaybackTask() -> Task<Void, Never>? {
        let operation = playbackOperation
        let task = operation?.task
        task?.cancel()
        operation?.preparationResult?.finish(false)
        return task
    }

    private func isCurrentPreparation(
        generation: UInt64,
        startLocator: Locator?
    ) -> Bool {
        guard
            generation == operationGeneration,
            let operation = playbackOperation,
            operation.generation == generation,
            case let .preparing(operationStartLocator) = operation.phase
        else {
            return false
        }
        return operationStartLocator == startLocator
    }

    private func setStartText(from startLocator: Locator?) {
        if let text = startLocator?.text, text.before != nil {
            startText = text
        } else {
            startText = nil
        }
    }

    /// Stops the synthesizer.
    ///
    /// Use `start()` to restart it.
    public func stop() {
        cancelPlaybackTask()
        operationGeneration &+= 1
        invalidatePrefetch()
        state = .stopped
        resetIterator(nil)
    }

    /// Interrupts a played utterance.
    ///
    /// Use `resume()` to restart the playback from the same utterance.
    public func pause() {
        cancelPlaybackTask()
        operationGeneration &+= 1
        invalidatePrefetch()
        if case let .playing(utterance, range: _) = state {
            state = .paused(utterance)
        }
    }

    /// Resumes an utterance interrupted with `pause()`.
    public func resume() {
        let oldPlaybackTask = cancelPlaybackTask()
        if case let .paused(utterance) = state {
            operationGeneration &+= 1
            let generation = operationGeneration
            let oldPrefetchTask = invalidatePrefetch()
            let task = Task { [weak self] in
                await oldPlaybackTask?.value
                await oldPrefetchTask?.value
                let weakSynthesizer: WeakPublicationSpeechSynthesizer
                let needsRollback: Bool
                if let self {
                    guard generation == self.operationGeneration else { return }
                    needsRollback = self.iteratorLedger.requiresRollback
                    weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
                } else {
                    return
                }
                if needsRollback {
                    await Self.rollbackForwardBuffer(
                        weakSynthesizer: weakSynthesizer,
                        generation: generation
                    )
                }
                await Self.continuePlaying(
                    weakSynthesizer: weakSynthesizer,
                    utterance: utterance,
                    generation: generation
                )
            }
            setPlaybackOperation(generation: generation, phase: .playing, task: task)
        }
    }

    /// Pauses or resumes the playback of the current utterance.
    public func pauseOrResume() {
        switch state {
        case .stopped: return
        case .playing: pause()
        case .paused: resume()
        }
    }

    /// Skips to the previous utterance.
    public func previous() {
        let oldPlaybackTask = cancelPlaybackTask()
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        let task = Task { [weak self] in
            await oldPlaybackTask?.value
            await oldPrefetchTask?.value
            let weakSynthesizer: WeakPublicationSpeechSynthesizer
            if let self {
                guard generation == self.operationGeneration else { return }
                weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
            } else {
                return
            }
            await Self.rollbackForwardBuffer(
                weakSynthesizer: weakSynthesizer,
                generation: generation
            )
            await Self.continuePlaying(
                weakSynthesizer: weakSynthesizer,
                utterance: nil,
                generation: generation,
                direction: .backward
            )
        }
        setPlaybackOperation(generation: generation, phase: .playing, task: task)
    }

    /// Skips to the next utterance.
    public func next() {
        let oldPlaybackTask = cancelPlaybackTask()
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        let task = Task { [weak self] in
            await oldPlaybackTask?.value
            await oldPrefetchTask?.value
            let weakSynthesizer: WeakPublicationSpeechSynthesizer
            let needsRollback: Bool
            if let self {
                guard generation == self.operationGeneration else { return }
                needsRollback = self.iteratorLedger.requiresRollback
                weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
            } else {
                return
            }
            if needsRollback {
                await Self.rollbackForwardBuffer(
                    weakSynthesizer: weakSynthesizer,
                    generation: generation
                )
            }
            await Self.continuePlaying(
                weakSynthesizer: weakSynthesizer,
                utterance: nil,
                generation: generation
            )
        }
        setPlaybackOperation(generation: generation, phase: .playing, task: task)
    }

    private var iteratorLedger = IteratorLedger()

    private func resetIterator(_ iterator: ContentIterator?) {
        utterances = CursorList()
        iteratorLedger.reset(iterator: iterator)
    }

    private var startText: Locator.Text?
    private var preparedStartLocator: Locator?
    private var preparedUtterance: Utterance?

    /// Utterances for the current publication `ContentElement` item.
    private var utterances: CursorList<Utterance> = CursorList()

    private func isCurrentOperation(
        _ generation: UInt64,
        iterator: ContentIterator? = nil
    ) -> Bool {
        !Task.isCancelled &&
            generation == operationGeneration &&
            playbackOperation?.generation == generation &&
            (iterator == nil || iteratorLedger.iterator === iterator)
    }

    private func isCurrentPlayingOperation(_ generation: UInt64) -> Bool {
        guard
            isCurrentOperation(generation),
            case .playing = playbackOperation?.phase
        else {
            return false
        }
        return true
    }

    /// Validates and commits the result of every user tokenizer call.
    ///
    /// Destination and movement identifiers select the ledger entry; payload
    /// equality only verifies that the selected entry still owns the token's
    /// once-prepared content. This is important when adjacent elements compare
    /// equal but belong to different iterator movements.
    private func commitTokenization(
        _ tokenized: [Utterance],
        source: TokenizationSource,
        token: OperationToken
    ) -> TokenCommitResult {
        guard
            !Task.isCancelled,
            token.playbackGeneration == operationGeneration,
            playbackOperation?.generation == token.playbackGeneration,
            iteratorLedger.owns(token.iterator)
        else {
            return .superseded
        }

        switch (source, token.destination) {
        case let (.bufferedPlayback, .playbackGroup(groupID)):
            guard iteratorLedger.matchesForwardGroup(
                groupID: groupID,
                movementID: token.movementID,
                raw: token.raw,
                prepared: token.prepared
            ) else {
                return .superseded
            }

        case let (.iteratorPlayback, .playbackMovement(direction)):
            guard iteratorLedger.matchesFetched(
                movementID: token.movementID,
                direction: direction,
                raw: token.raw,
                prepared: token.prepared
            ) else {
                return .superseded
            }

        case let (.forwardGroupLoader, .forwardGroup(groupID)),
             let (.forwardCandidateCollection, .forwardCandidate(groupID)):
            guard iteratorLedger.matchesForwardGroup(
                groupID: groupID,
                movementID: token.movementID,
                raw: token.raw,
                prepared: token.prepared
            ) else {
                return .superseded
            }

        default:
            return .superseded
        }

        if source.isForwardOperation {
            guard
                token.prefetchGeneration == prefetchGeneration,
                let forwardTaskID = token.forwardTaskID,
                isCurrentForwardPrefetch(
                    taskID: forwardTaskID,
                    generation: token.prefetchGeneration
                )
            else {
                // A forward epoch never retries inside its retired worker. Its
                // successor will lease the preserved placeholder.
                return .superseded
            }
        } else {
            guard token.forwardTaskID == nil else { return .superseded }
            if token.prefetchGeneration != prefetchGeneration {
                // Config invalidation does not retire the live playback worker.
                // Retry the same ledger entry using its prepared payload.
                return .retryWithNewConfig
            }
        }

        switch token.destination {
        case let .playbackMovement(direction):
            guard iteratorLedger.completeFetched(
                movementID: token.movementID,
                direction: direction
            ) else {
                return .superseded
            }
            if !tokenized.isEmpty {
                utterances = CursorList(
                    list: tokenized,
                    startIndex: direction == .forward ? 0 : tokenized.count - 1
                )
            }

        case let .playbackGroup(groupID):
            guard iteratorLedger.consumeForwardGroup(
                groupID: groupID,
                utterances: tokenized
            ) else {
                return .superseded
            }
            if !tokenized.isEmpty {
                utterances = CursorList(list: tokenized, startIndex: 0)
            }

        case let .forwardGroup(groupID), let .forwardCandidate(groupID):
            guard iteratorLedger.fillForwardPlaceholder(
                groupID: groupID,
                utterances: tokenized
            ) else {
                return .superseded
            }
        }

        return .committed(tokenized)
    }

    /// Releases a tokenizer lease without discarding its prepared payload.
    /// Fetched playback movements remain in `.fetched` and need no transition.
    private func recoverTokenizationLease(_ token: OperationToken) {
        guard iteratorLedger.owns(token.iterator) else { return }
        switch token.destination {
        case let .playbackGroup(groupID),
             let .forwardGroup(groupID),
             let .forwardCandidate(groupID):
            iteratorLedger.restoreForwardGroup(groupID: groupID)
        case .playbackMovement:
            break
        }
    }

    /// Playback worker that only weakly references the synthesizer across
    /// `engine.speak` and look-ahead waits, so releasing the last external
    /// reference can run `deinit` and cancel outstanding work.
    private static func continuePlaying(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        utterance: Utterance?,
        generation: UInt64,
        direction: Direction = .forward
    ) async {
        var pendingUtterance = utterance
        var loadDirection = direction

        while true {
            let toPlay: Utterance
            if let pending = pendingUtterance {
                toPlay = pending
                pendingUtterance = nil
            } else {
                // nextUtterance rebinds weak self around each suspension.
                guard let next = await nextUtterance(
                    weakSynthesizer: weakSynthesizer,
                    direction: loadDirection,
                    generation: generation
                ) else {
                    if let self = weakSynthesizer.value, self.isCurrentPlayingOperation(generation) {
                        self.state = .stopped
                    }
                    return
                }
                loadDirection = .forward
                toPlay = next
            }

            let shouldContinue = await playOneUtterance(
                weakSynthesizer: weakSynthesizer,
                utterance: toPlay,
                generation: generation
            )
            if !shouldContinue {
                return
            }
        }
    }

    /// Speaks a single utterance without retaining the synthesizer across
    /// engine or look-ahead suspensions. Returns whether automatic forward
    /// continuation should proceed.
    private static func playOneUtterance(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        utterance: Utterance,
        generation: UInt64
    ) async -> Bool {
        let prepared: (engine: TTSEngine, ttsUtterance: TTSUtterance)
        if let self = weakSynthesizer.value {
            guard self.isCurrentPlayingOperation(generation) else {
                return false
            }
            prepared = (self.engine, self.ttsUtterance(for: utterance))
            self.state = .playing(utterance, range: nil)
            // Delegate may stop/cancel synchronously from stateDidChange.
            guard self.isCurrentPlayingOperation(generation) else {
                return false
            }
        } else {
            return false
        }

        final class PrefetchStartFlag: @unchecked Sendable {
            var didStart = false
        }
        let prefetchStart = PrefetchStartFlag()

        let result = await prepared.engine.speak(
            prepared.ttsUtterance,
            onSpeakRange: { range in
                guard let self = weakSynthesizer.value else { return }
                guard self.isCurrentPlayingOperation(generation) else { return }

                self.state = .playing(
                    utterance,
                    range: utterance.locator.copy(
                        text: { text in
                            guard
                                let highlight = text.highlight,
                                highlight.startIndex <= range.lowerBound, highlight.endIndex >= range.upperBound
                            else {
                                return
                            }
                            text = text[range]
                        }
                    )
                )
                guard self.isCurrentPlayingOperation(generation) else { return }
                if !prefetchStart.didStart {
                    prefetchStart.didStart = true
                    self.startForwardPrefetch(generation: generation)
                }
            }
        )

        switch result {
        case .success:
            // Snapshot wait decision in a short strong-self scope so the waiter
            // suspension does not retain the synthesizer.
            let shouldWait: Bool
            let prefetchGeneration: UInt64
            let forwardTaskID: UInt64?
            if let self = weakSynthesizer.value {
                guard self.isCurrentPlayingOperation(generation) else {
                    return false
                }
                let operation = self.forwardPrefetchOperation
                shouldWait = operation?.ready.isEmpty == true
                prefetchGeneration = operation?.generation ?? self.prefetchGeneration
                forwardTaskID = operation?.taskID
            } else {
                return false
            }

            if shouldWait, let forwardTaskID {
                await waitUntilNextForwardReadyOrFinished(
                    weakSynthesizer: weakSynthesizer,
                    operationGeneration: generation,
                    prefetchGeneration: prefetchGeneration,
                    forwardTaskID: forwardTaskID
                )
            }

            // Drain cancellation without retaining self across the await.
            let cancellation: Task<Void, Never>?
            if let self = weakSynthesizer.value {
                guard self.isCurrentPlayingOperation(generation) else {
                    return false
                }
                cancellation = self.latestRetiredForwardPrefetchDrain
            } else {
                return false
            }
            await cancellation?.value

            if let self = weakSynthesizer.value {
                guard self.isCurrentPlayingOperation(generation) else {
                    return false
                }
                self.consumeReadyForwardPrefetch()
                return true
            }
            return false
        case let .failure(error):
            guard let self = weakSynthesizer.value else { return false }
            self.invalidatePrefetch()
            self.state = .paused(utterance)
            self.delegate?.publicationSpeechSynthesizer(
                self,
                utterance: utterance,
                didFailWithError: .engine(error)
            )
            return false
        }
    }

    private func ttsUtterance(for utterance: Utterance) -> TTSUtterance {
        TTSUtterance(
            text: utterance.text,
            delay: 0,
            prefetchIdentifier: utterance.prefetchIdentifier,
            voiceOrLanguage: voiceOrLanguage(for: utterance)
        )
    }

    /// Returns the user selected voice if it's compatible with the utterance language. Otherwise, falls back on
    /// the languages.
    private func voiceOrLanguage(for utterance: Utterance) -> Either<TTSVoice, Language> {
        if let voice = config.voiceIdentifier
            .flatMap({ id in self.voiceWithIdentifier(id) })
            .takeIf({ voice in utterance.language == nil || utterance.language?.removingRegion() == voice.language.removingRegion() })
        {
            return .left(voice)
        } else {
            return .right(utterance.language
                ?? config.defaultLanguage
                ?? publication.metadata.language
                ?? Language.current)
        }
    }

    /// Gets the next utterance. Re-resolves weak self between cursor take and
    /// content load so releasing the owner mid-load can complete deinit.
    private static func nextUtterance(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        direction: Direction,
        generation: UInt64
    ) async -> Utterance? {
        while true {
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation) else { return nil }
                if let utterance = self.utterances.next(direction) {
                    return utterance
                }
            } else {
                return nil
            }
            let loaded = await loadNextUtterances(
                weakSynthesizer: weakSynthesizer,
                direction: direction,
                generation: generation
            )
            if !loaded {
                return nil
            }
        }
    }

    /// Loads the next content block for playback without retaining the
    /// synthesizer across `iterator.next` / `previous` suspensions.
    ///
    /// Empty buffered groups are drained iteratively (never via a recursive
    /// await under a strong `self` binding) so a subsequent hanging
    /// `iterator.next` cannot re-form self → playback operation → self.
    private static func loadNextUtterances(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        direction: Direction,
        generation: UInt64
    ) async -> Bool {
        while true {
            if direction == .forward {
                enum GroupStep {
                    case use(IteratorLedger.GroupLease, ContentIterator)
                    case none
                }
                let step: GroupStep
                if let self = weakSynthesizer.value {
                    guard self.isCurrentOperation(generation) else { return false }
                    if !self.iteratorLedger.hasForwardGroups {
                        step = .none
                    } else if
                        let iterator = self.iteratorLedger.iterator,
                        let group = self.iteratorLedger.leaseFirstForwardGroup()
                    {
                        step = .use(group, iterator)
                    } else {
                        return false
                    }
                } else {
                    return false
                }

                switch step {
                case .none:
                    break // fall through to iterator load

                case let .use(group, iterator):
                    // Retokenize under short self scopes; may loop if config re-enters.
                    let committed = await consumeForwardGroup(
                        weakSynthesizer: weakSynthesizer,
                        group: group,
                        iterator: iterator,
                        generation: generation
                    )
                    switch committed {
                    case .ready:
                        return true
                    case .emptyContinue:
                        // Strong self already dropped — iterate to next group / iterator.
                        continue
                    case .failed:
                        return false
                    }
                }
            }

            return await loadNextUtterancesFromIterator(
                weakSynthesizer: weakSynthesizer,
                direction: direction,
                generation: generation
            )
        }
    }

    private enum ForwardGroupConsumeResult {
        case ready
        case emptyContinue
        case failed
    }

    /// Consumes one buffered forward group. Retokenizes when `utterances == nil`,
    /// re-checking operation + config (prefetch) epochs after tokenizer reentry.
    private static func consumeForwardGroup(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        group: IteratorLedger.GroupLease,
        iterator: ContentIterator,
        generation: UInt64
    ) async -> ForwardGroupConsumeResult {
        func restorePending() {
            guard let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) else {
                return
            }
            self.iteratorLedger.restoreForwardGroup(groupID: group.groupID)
        }

        if let existing = group.utterances {
            guard let self = weakSynthesizer.value else { return .failed }
            guard self.isCurrentOperation(generation, iterator: iterator) else {
                restorePending()
                return .failed
            }
            guard self.iteratorLedger.consumeForwardGroup(
                groupID: group.groupID,
                utterances: existing
            ) else {
                return .failed
            }
            if existing.isEmpty {
                return .emptyContinue
            }
            self.utterances = CursorList(list: existing, startIndex: 0)
            return .ready
        }

        // The ledger placeholder already owns the once-prepared content. Config
        // retries re-run only the config-sensitive tokenizer.
        var configRetries = 0
        while true {
            let token: OperationToken
            let tokenized: [Utterance]
            if let self = weakSynthesizer.value {
                token = OperationToken(
                    playbackGeneration: generation,
                    prefetchGeneration: self.prefetchGeneration,
                    forwardTaskID: nil,
                    iterator: iterator,
                    movementID: group.movementID,
                    destination: .playbackGroup(id: group.groupID),
                    raw: group.raw,
                    prepared: group.prepared
                )
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    self.recoverTokenizationLease(token)
                    return .failed
                }
                do {
                    tokenized = try self.tokenizePrepared(token.prepared)
                        .flatMap { self.utterances(for: $0) }
                } catch {
                    if let self = weakSynthesizer.value {
                        self.recoverTokenizationLease(token)
                        self.log(.error, error)
                    }
                    return .failed
                }
            } else {
                return .failed
            }

            guard let self = weakSynthesizer.value else { return .failed }
            switch self.commitTokenization(
                tokenized,
                source: .bufferedPlayback,
                token: token
            ) {
            case let .committed(committed):
                return committed.isEmpty ? .emptyContinue : .ready

            case .retryWithNewConfig:
                configRetries += 1
                if configRetries > Self.maximumConfigTokenizeRetries {
                    // Leave group pending for a later epoch; do not spin on MainActor.
                    self.recoverTokenizationLease(token)
                    return .failed
                }
                continue

            case .superseded:
                self.recoverTokenizationLease(token)
                return .failed
            }
        }
    }

    private static func loadNextUtterancesFromIterator(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        direction: Direction,
        generation: UInt64
    ) async -> Bool {
        let iterator: ContentIterator
        if let self = weakSynthesizer.value {
            guard self.isCurrentOperation(generation) else { return false }
            guard let current = self.iteratorLedger.iterator else { return false }
            iterator = current
        } else {
            return false
        }

        contentLoop: while true {
            let load: IteratorLedger.LiveStep
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }
                load = self.iteratorLedger.beginLiveStep(direction: direction)
            } else {
                return false
            }

            let movement: IteratorLedger.FetchedMovement
            switch load {
            case let .ready(readyMovement):
                movement = readyMovement

            case let .opposite(undo):
                // Iterator may return the element even when the task is cancelled.
                let moved: ContentElement?
                do {
                    moved = try await iterator.next(undo.originalDirection.opposite)
                } catch {
                    if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                        self.iteratorLedger.restoreUndo(undo)
                        if !(error is CancellationError) {
                            self.log(.error, error)
                        }
                    }
                    return false
                }
                guard moved != nil else {
                    if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                        self.iteratorLedger.restoreUndo(undo)
                    }
                    return false
                }

                // The cursor moved: clear undo accounting before validating the
                // operation that awaited it.
                if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                    self.iteratorLedger.completeUndo(movementID: undo.movementID)
                }
                guard let self = weakSynthesizer.value else { return false }
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }
                continue

            case .fetch:
                let raw: ContentElement?
                do {
                    raw = try await iterator.next(direction)
                } catch {
                    if !(error is CancellationError), let self = weakSynthesizer.value {
                        self.log(.error, error)
                    }
                    return false
                }
                guard let raw else { return false }
                guard let self = weakSynthesizer.value else { return false }
                guard self.iteratorLedger.owns(iterator) else { return false }

                // Preparation and movement accounting happen exactly once and
                // before any stale-generation exit.
                let prepared = self.applyingStartTextIfNeeded(raw)
                let movementID = UUID()
                self.iteratorLedger.recordFetched(
                    movementID: movementID,
                    direction: direction,
                    raw: raw,
                    prepared: prepared
                )
                movement = IteratorLedger.FetchedMovement(
                    movementID: movementID,
                    direction: direction,
                    raw: raw,
                    prepared: prepared
                )
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }

            case .unavailable:
                return false
            }

            var configRetries = 0
            while true {
                let token: OperationToken
                let tokenized: [Utterance]
                if let self = weakSynthesizer.value {
                    guard self.isCurrentOperation(generation, iterator: iterator) else {
                        return false
                    }
                    token = OperationToken(
                        playbackGeneration: generation,
                        prefetchGeneration: self.prefetchGeneration,
                        forwardTaskID: nil,
                        iterator: iterator,
                        movementID: movement.movementID,
                        destination: .playbackMovement(direction: direction),
                        raw: movement.raw,
                        prepared: movement.prepared
                    )
                    do {
                        tokenized = try self.tokenizePrepared(token.prepared)
                            .flatMap { self.utterances(for: $0) }
                    } catch {
                        if let self = weakSynthesizer.value {
                            self.recoverTokenizationLease(token)
                            self.log(.error, error)
                        }
                        return false
                    }
                } else {
                    return false
                }

                guard let self = weakSynthesizer.value else { return false }
                switch self.commitTokenization(
                    tokenized,
                    source: .iteratorPlayback,
                    token: token
                ) {
                case let .committed(committed):
                    if committed.isEmpty {
                        continue contentLoop
                    }
                    return true

                case .retryWithNewConfig:
                    configRetries += 1
                    if configRetries > Self.maximumConfigTokenizeRetries {
                        // The same prepared fetched movement remains recoverable.
                        self.recoverTokenizationLease(token)
                        return false
                    }
                    continue

                case .superseded:
                    self.recoverTokenizationLease(token)
                    return false
                }
            }
        }
    }

    private func startForwardPrefetch(
        generation: UInt64,
        prefetchGeneration requestedPrefetchGeneration: UInt64? = nil
    ) {
        if readyForwardPrefetchOperation?.ready.isEmpty == true {
            readyForwardPrefetchOperation = nil
        }
        guard
            forwardPrefetchOperation == nil,
            readyForwardPrefetchOperation == nil,
            engine is TTSPrefetchingEngine
        else {
            return
        }
        let prefetchGeneration: UInt64
        if let requestedPrefetchGeneration {
            prefetchGeneration = requestedPrefetchGeneration
        } else {
            self.prefetchGeneration &+= 1
            prefetchGeneration = self.prefetchGeneration
        }
        let predecessorDrain = latestRetiredForwardPrefetchDrain
        nextForwardPrefetchTaskID &+= 1
        let taskID = nextForwardPrefetchTaskID
        let maximumPrefetchDuration = Self.maximumPrefetchDuration
        let maximumSingleDuration = Self.maximumSingleUtterancePrefetchDuration
        // Unstructured, MainActor-inherited task. Re-resolve `self` weakly around
        // every suspension (`iterator.next` and `engine.prefetch`) so neither a
        // gated content load nor multi-second neural synth pins the synthesizer
        // via self → task → self.
        let task = Task { [weak self] in
            await predecessorDrain?.value
            defer {
                self?.finishForwardPrefetch(
                    taskID: taskID,
                    generation: prefetchGeneration
                )
            }

            var candidates: [Utterance] = []
            var candidateIndex = 0
            var prefetchedIdentifiers = Set<UUID>()
            var duration: TimeInterval = 0

            if let self {
                guard
                    generation == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration,
                    self.isCurrentForwardPrefetch(
                        taskID: taskID,
                        generation: prefetchGeneration
                    )
                else {
                    return
                }
                // Re-tokenize config-invalidated groups (`utterances == nil`) in
                // order before reading further from the iterator — never skip
                // over pending buffer slots to later content.
                do {
                    guard let collected = try self.collectForwardPrefetchCandidates(
                        operationGeneration: generation,
                        prefetchGeneration: prefetchGeneration,
                        forwardTaskID: taskID
                    ) else {
                        return
                    }
                    candidates = collected
                } catch {
                    self.log(.error, error)
                    return
                }
                guard
                    generation == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration,
                    self.isCurrentForwardPrefetch(
                        taskID: taskID,
                        generation: prefetchGeneration
                    )
                else {
                    return
                }
                guard let operation = self.activeForwardPrefetchOperation(
                    taskID: taskID,
                    generation: prefetchGeneration
                ) else {
                    return
                }
                prefetchedIdentifiers = Set(operation.ready.map(\.identifier))
                duration = operation.ready.reduce(into: 0) { $0 += $1.duration }
            } else {
                return
            }

            while duration < maximumPrefetchDuration {
                if candidateIndex == candidates.count {
                    let loaded = await Self.loadNextForwardGroup(
                        weakSynthesizer: WeakPublicationSpeechSynthesizer(self),
                        operationGeneration: generation,
                        prefetchGeneration: prefetchGeneration,
                        forwardTaskID: taskID
                    )
                    switch loaded {
                    case let .group(utterances):
                        candidates.append(contentsOf: utterances)
                        continue
                    case .finished:
                        // End of content, cancel, or failure — defer wakes waiters.
                        return
                    }
                }

                let utterance = candidates[candidateIndex]
                candidateIndex += 1
                guard prefetchedIdentifiers.insert(utterance.prefetchIdentifier).inserted else {
                    continue
                }

                // Build locals under a short strong-self scope so `self` is not
                // retained across the engine.prefetch suspension.
                struct PreparedPrefetch {
                    let engine: TTSPrefetchingEngine
                    let utterance: TTSUtterance
                    let identifier: UUID
                }

                let prepared: PreparedPrefetch
                if let self {
                    guard
                        !Task.isCancelled,
                        generation == self.operationGeneration,
                        prefetchGeneration == self.prefetchGeneration,
                        self.isCurrentForwardPrefetch(
                            taskID: taskID,
                            generation: prefetchGeneration
                        )
                    else {
                        return
                    }
                    guard let engine = self.engine as? TTSPrefetchingEngine else {
                        return
                    }
                    prepared = PreparedPrefetch(
                        engine: engine,
                        utterance: self.ttsUtterance(for: utterance),
                        identifier: utterance.prefetchIdentifier
                    )
                } else {
                    return
                }

                let prefetchedDuration = await prepared.engine.prefetch(
                    prepared.utterance,
                    maximumDuration: maximumSingleDuration
                )

                guard let prefetchedDuration else {
                    // Prefetch failure — defer wakes waiters for live fallback.
                    return
                }
                guard
                    prefetchedDuration.isFinite,
                    prefetchedDuration > 0,
                    prefetchedDuration <= maximumSingleDuration
                else {
                    return
                }
                let didAppend: Bool
                if let self {
                    didAppend = self.appendReadyForwardPrefetch(
                        ForwardPrefetch(
                            identifier: prepared.identifier,
                            duration: prefetchedDuration
                        ),
                        operationGeneration: generation,
                        taskID: taskID,
                        generation: prefetchGeneration
                    )
                } else {
                    return
                }
                guard didAppend else { return }
                duration += prefetchedDuration
                // Let resumed waiters run on MainActor before more look-ahead.
                await Task.yield()
            }
        }
        forwardPrefetchOperation = ForwardPrefetchOperation(
            generation: prefetchGeneration,
            taskID: taskID,
            task: task,
            ready: [],
            waiters: ContinuationRegistry(),
            cancellationTask: nil
        )
        forwardPrefetchLifecycle.setTask(task)
    }

    private enum ForwardGroupLoadResult {
        case group([Utterance])
        case finished
    }

    /// Loads the next content group for look-ahead without retaining the
    /// synthesizer across `iterator.next()` suspensions (only a weak box is held).
    private static func loadNextForwardGroup(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        operationGeneration: UInt64,
        prefetchGeneration: UInt64,
        forwardTaskID: UInt64
    ) async -> ForwardGroupLoadResult {
        let iterator: ContentIterator
        if let synthesizer = weakSynthesizer.value {
            guard
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration,
                synthesizer.isCurrentForwardPrefetch(
                    taskID: forwardTaskID,
                    generation: prefetchGeneration
                ),
                let currentIterator = synthesizer.iteratorLedger.iterator
            else {
                return .finished
            }
            iterator = currentIterator
        } else {
            return .finished
        }

        while true {
            let step: IteratorLedger.ForwardStep
            if let synthesizer = weakSynthesizer.value {
                guard
                    synthesizer.iteratorLedger.owns(iterator),
                    !Task.isCancelled,
                    operationGeneration == synthesizer.operationGeneration,
                    prefetchGeneration == synthesizer.prefetchGeneration,
                    synthesizer.isCurrentForwardPrefetch(
                        taskID: forwardTaskID,
                        generation: prefetchGeneration
                    )
                else {
                    return .finished
                }
                step = synthesizer.iteratorLedger.beginForwardStep()
            } else {
                return .finished
            }

            let placeholder: IteratorLedger.GroupLease
            switch step {
            case let .placeholder(existing):
                placeholder = existing

            case .unavailable:
                return .finished

            case .fetch:
                // No strong synthesizer across the iterator suspension.
                let content: ContentElement?
                do {
                    content = try await iterator.next()
                } catch is CancellationError {
                    return .finished
                } catch {
                    if let synthesizer = weakSynthesizer.value {
                        synthesizer.log(.error, error)
                    }
                    return .finished
                }

                guard let content else { return .finished }

                guard let synthesizer = weakSynthesizer.value else { return .finished }
                guard synthesizer.iteratorLedger.owns(iterator) else { return .finished }

                // Prepare and record the movement before looking at stale operation
                // generations, then install a stable ledger placeholder before any
                // tokenizer can re-enter.
                let prepared = synthesizer.applyingStartTextIfNeeded(content)
                let movementID = UUID()
                synthesizer.iteratorLedger.recordFetched(
                    movementID: movementID,
                    direction: .forward,
                    raw: content,
                    prepared: prepared
                )
                guard let created = synthesizer.iteratorLedger.createForwardPlaceholder(
                    movementID: movementID
                ) else {
                    return .finished
                }
                placeholder = created
            }

            guard let synthesizer = weakSynthesizer.value else { return .finished }
            let token = OperationToken(
                playbackGeneration: operationGeneration,
                prefetchGeneration: prefetchGeneration,
                forwardTaskID: forwardTaskID,
                iterator: iterator,
                movementID: placeholder.movementID,
                destination: .forwardGroup(id: placeholder.groupID),
                raw: placeholder.raw,
                prepared: placeholder.prepared
            )
            guard
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration,
                synthesizer.isCurrentForwardPrefetch(
                    taskID: forwardTaskID,
                    generation: prefetchGeneration
                )
            else {
                synthesizer.recoverTokenizationLease(token)
                return .finished
            }
            let tokenized: [Utterance]
            do {
                tokenized = try synthesizer.tokenizePrepared(token.prepared)
                    .flatMap { synthesizer.utterances(for: $0) }
            } catch {
                if let synthesizer = weakSynthesizer.value {
                    synthesizer.recoverTokenizationLease(token)
                    synthesizer.log(.error, error)
                }
                return .finished
            }

            guard let synthesizer = weakSynthesizer.value else { return .finished }
            switch synthesizer.commitTokenization(
                tokenized,
                source: .forwardGroupLoader,
                token: token
            ) {
            case let .committed(committed):
                if !committed.isEmpty {
                    return .group(committed)
                }

            case .retryWithNewConfig, .superseded:
                synthesizer.recoverTokenizationLease(token)
                return .finished
            }
        }
    }

    /// Marks a normally completed forward operation ready for consumption.
    /// No-ops after invalidation moved the operation into the retired collection.
    private func finishForwardPrefetch(
        taskID: UInt64,
        generation: UInt64
    ) {
        guard
            let operation = activeForwardPrefetchOperation(
                taskID: taskID,
                generation: generation
            )
        else {
            return
        }
        forwardPrefetchOperation = nil
        forwardPrefetchLifecycle.clearTask()
        operation.waiters.resumeAll()
        if !operation.ready.isEmpty {
            readyForwardPrefetchOperation = operation
        }
    }

    private func isCurrentForwardPrefetch(
        taskID: UInt64,
        generation: UInt64
    ) -> Bool {
        activeForwardPrefetchOperation(
            taskID: taskID,
            generation: generation
        ) != nil
    }

    private func activeForwardPrefetchOperation(
        taskID: UInt64,
        generation: UInt64
    ) -> ForwardPrefetchOperation? {
        guard
            let operation = forwardPrefetchOperation,
            operation.taskID == taskID,
            operation.generation == generation
        else {
            return nil
        }
        return operation
    }

    @discardableResult
    private func appendReadyForwardPrefetch(
        _ ready: ForwardPrefetch,
        operationGeneration: UInt64,
        taskID: UInt64,
        generation: UInt64
    ) -> Bool {
        guard
            !Task.isCancelled,
            operationGeneration == self.operationGeneration,
            generation == prefetchGeneration,
            var operation = activeForwardPrefetchOperation(
                taskID: taskID,
                generation: generation
            )
        else {
            return false
        }
        operation.ready.append(ready)
        forwardPrefetchOperation = operation
        // Ready insertion and waiter lookup use the same operation identity.
        // Resume only that operation's consumers after its queue is committed.
        operation.waiters.resumeAll()
        return true
    }

    private func consumeReadyForwardPrefetch() {
        if
            var operation = forwardPrefetchOperation,
            operation.generation == prefetchGeneration,
            !operation.ready.isEmpty
        {
            operation.ready.removeFirst()
            forwardPrefetchOperation = operation
            return
        }
        if
            var operation = readyForwardPrefetchOperation,
            operation.generation == prefetchGeneration,
            !operation.ready.isEmpty
        {
            operation.ready.removeFirst()
            readyForwardPrefetchOperation = operation.ready.isEmpty ? nil : operation
        }
    }

    private var latestRetiredForwardPrefetchDrain: Task<Void, Never>? {
        retiredForwardPrefetchOperations.values
            .max { $0.taskID < $1.taskID }?
            .cancellationTask
    }

    /// Builds look-ahead candidates from the current cursor and ledger groups,
    /// re-tokenizing any groups whose utterances were cleared by a config change.
    /// Does not advance the publication iterator.
    ///
    /// Returns `nil` when reentrant tokenizer work invalidated this look-ahead
    /// epoch (stop/navigation or superseded prefetch generation) so callers
    /// abort instead of committing stale results or writing past a cleared buffer.
    private func collectForwardPrefetchCandidates(
        operationGeneration: UInt64,
        prefetchGeneration: UInt64,
        forwardTaskID: UInt64
    ) throws -> [Utterance]? {
        var candidates = Array(utterances.elementsAfterCurrent())
        let groupIDs = iteratorLedger.forwardGroupIDs()
        for groupID in groupIDs {
            guard let group = iteratorLedger.forwardGroup(groupID: groupID) else {
                continue
            }
            if let existing = group.utterances {
                candidates.append(contentsOf: existing)
                continue
            }

            guard let leased = iteratorLedger.leaseForwardGroup(groupID: groupID) else {
                return nil
            }
            guard let iterator = iteratorLedger.iterator else {
                iteratorLedger.restoreForwardGroup(groupID: groupID)
                return nil
            }
            let token = OperationToken(
                playbackGeneration: operationGeneration,
                prefetchGeneration: prefetchGeneration,
                forwardTaskID: forwardTaskID,
                iterator: iterator,
                movementID: leased.movementID,
                destination: .forwardCandidate(id: leased.groupID),
                raw: leased.raw,
                prepared: leased.prepared
            )
            let tokenized: [Utterance]
            do {
                tokenized = try tokenizePrepared(token.prepared)
                    .flatMap { utterances(for: $0) }
            } catch {
                recoverTokenizationLease(token)
                throw error
            }

            switch commitTokenization(
                tokenized,
                source: .forwardCandidateCollection,
                token: token
            ) {
            case let .committed(committed):
                candidates.append(contentsOf: committed)

            case .retryWithNewConfig, .superseded:
                recoverTokenizationLease(token)
                return nil
            }
        }
        return candidates
    }

    /// Suspends until the next forward item is ready, the forward task ends
    /// (failure / end of content / cancel), or generations no longer match.
    ///
    /// Check-and-register runs in one MainActor-synchronous section so a ready
    /// or finished event cannot slip between the empty check and the waiter list.
    /// Does not retain the synthesizer across the suspension. Continuations are
    /// stored in `ContinuationRegistry` so deinit/cancel can still resume them.
    private static func waitUntilNextForwardReadyOrFinished(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        operationGeneration: UInt64,
        prefetchGeneration: UInt64,
        forwardTaskID: UInt64
    ) async {
        guard
            let initial = weakSynthesizer.value?.activeForwardPrefetchOperation(
                taskID: forwardTaskID,
                generation: prefetchGeneration
            )
        else {
            return
        }
        let waiters = initial.waiters
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let self = weakSynthesizer.value else {
                    continuation.resume()
                    return
                }
                guard
                    !Task.isCancelled,
                    operationGeneration == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration,
                    let operation = self.activeForwardPrefetchOperation(
                        taskID: forwardTaskID,
                        generation: prefetchGeneration
                    )
                else {
                    continuation.resume()
                    return
                }
                if !operation.ready.isEmpty {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
            }
        } onCancel: {
            waiters.resumeAll()
        }
    }

    private func cancelInitialPrefetchIfCurrent(
        operationGeneration: UInt64,
        startLocator: Locator?,
        prefetchGeneration: UInt64
    ) {
        guard
            isCurrentPreparation(
                generation: operationGeneration,
                startLocator: startLocator
            ),
            prefetchGeneration == self.prefetchGeneration
        else {
            return
        }
        cancelPlaybackTask()
        invalidatePrefetch()
    }

    @discardableResult
    private func invalidatePrefetch() -> Task<Void, Never>? {
        prefetchGeneration &+= 1
        preparedStartLocator = nil
        preparedUtterance = nil

        let activeOperation = forwardPrefetchOperation
        forwardPrefetchOperation = nil
        let readyOperation = readyForwardPrefetchOperation
        readyForwardPrefetchOperation = nil
        // Drop lifecycle ownership before cancel so deinit of a racing release
        // does not double-cancel after we finish sequencing below.
        forwardPrefetchLifecycle.clearTask()
        activeOperation?.waiters.resumeAll()
        readyOperation?.waiters.resumeAll()
        activeOperation?.task.cancel()
        // Always wake waiters: stop/pause/next/previous/config must not deadlock
        // on a pending forward-ready continuation.
        // Still on MainActor here — call the isolated engine API directly.
        let engine = engineStorage as? TTSPrefetchingEngine
        engine?.cancelPrefetch()

        guard var retiredOperation = activeOperation else {
            return latestRetiredForwardPrefetchDrain
        }
        let taskID = retiredOperation.taskID
        let generation = retiredOperation.generation
        let task = retiredOperation.task
        let drain = Task { [weak self] in
            await task.value
            self?.finishRetiredForwardPrefetch(
                taskID: taskID,
                generation: generation
            )
        }
        retiredOperation.ready = []
        retiredOperation.cancellationTask = drain
        retiredForwardPrefetchOperations[taskID] = retiredOperation
        return drain
    }

    private func finishRetiredForwardPrefetch(
        taskID: UInt64,
        generation: UInt64
    ) {
        guard
            let operation = retiredForwardPrefetchOperations[taskID],
            operation.generation == generation
        else {
            return
        }
        operation.waiters.resumeAll()
        retiredForwardPrefetchOperations[taskID] = nil
    }

    private static func rollbackForwardBuffer(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        generation: UInt64
    ) async {
        let iterator: ContentIterator
        let fetchedUndo: IteratorLedger.UndoMovement?
        if let self = weakSynthesizer.value {
            guard self.isCurrentOperation(generation) else { return }
            guard let current = self.iteratorLedger.iterator else { return }
            iterator = current
            fetchedUndo = self.iteratorLedger.beginFetchedUndoForRollback()
        } else {
            return
        }

        if let fetchedUndo {
            let moved: ContentElement?
            do {
                moved = try await iterator.previous()
            } catch {
                if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                    self.iteratorLedger.restoreUndo(fetchedUndo)
                    if !(error is CancellationError) {
                        self.log(.error, error)
                    }
                }
                return
            }
            guard moved != nil else {
                if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                    self.iteratorLedger.restoreUndo(fetchedUndo)
                }
                return
            }
            // Clear the fetched undo before checking whether this rollback was
            // superseded. Buffered/trailing work remains ledger-owned for the
            // current or successor operation.
            if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                self.iteratorLedger.completeUndo(movementID: fetchedUndo.movementID)
            }
            guard let self = weakSynthesizer.value,
                  self.isCurrentOperation(generation, iterator: iterator)
            else {
                return
            }
        }

        let advanceCount: Int
        if let self = weakSynthesizer.value {
            guard self.isCurrentOperation(generation, iterator: iterator) else { return }
            guard let work = self.iteratorLedger.beginRollback() else { return }
            guard work.iterator === iterator else { return }
            advanceCount = work.count
        } else {
            return
        }

        for _ in 0 ..< advanceCount {
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else { return }
            } else {
                return
            }

            let moved: ContentElement?
            do {
                moved = try await iterator.previous()
            } catch is CancellationError {
                return
            } catch {
                if let self = weakSynthesizer.value {
                    self.log(.error, error)
                }
                return
            }

            guard moved != nil else { return }
            // Persist the reverse movement before checking whether the operation
            // that awaited it was superseded.
            if let self = weakSynthesizer.value, self.iteratorLedger.owns(iterator) {
                self.iteratorLedger.completeRollbackMovement()
            }
        }
    }

    /// Maximum times a single content block may re-tokenize after config reentry
    /// during one load. Prevents a hostile/custom tokenizer from livelocking the
    /// MainActor by flipping config on every call.
    private static let maximumConfigTokenizeRetries = 8

    /// Applies locator `startText` trimming at most once per synthesizer start
    /// position, producing content that can be re-tokenized under changing
    /// configs without losing the trim.
    private func applyingStartTextIfNeeded(_ element: ContentElement) -> ContentElement {
        guard
            let startText,
            var first = element as? TextContentElement
        else {
            return element
        }
        self.startText = nil
        if let offset = textOffset(in: first, for: startText) {
            first.segments = trimming(first.segments, before: offset)
        }
        return first
    }

    /// Config-sensitive sentence split only (no locator trim).
    private func tokenizePrepared(_ element: ContentElement) throws -> [ContentElement] {
        let tokenizer = tokenizerFactory(config.defaultLanguage ?? publication.metadata.language)
        return try tokenizer(element)
    }

    /// Splits a publication `ContentElement` item into smaller chunks using the provided tokenizer.
    ///
    /// This is used to split a paragraph into sentences, for example.
    func tokenize(_ element: ContentElement) throws -> [ContentElement] {
        try tokenizePrepared(applyingStartTextIfNeeded(element))
    }

    private func textOffset(in element: TextContentElement, for startText: Locator.Text) -> Int? {
        guard let before = startText.before else {
            return nil
        }

        let text = element.segments.map(\.text).joined()
        let normalized = coalescingWhitespace(in: text)
        let normalizedBefore = coalescingWhitespace(in: before).text
        if let offset = normalized.rawOffset(afterPrefix: normalizedBefore) {
            return offset
        }

        return nil
    }

    private func trimming(
        _ segments: [TextContentElement.Segment],
        before offset: Int
    ) -> [TextContentElement.Segment] {
        var remaining = offset
        for index in segments.indices {
            guard remaining < segments[index].text.count else {
                remaining -= segments[index].text.count
                continue
            }
            var first = segments[index]
            first.text = String(first.text.dropFirst(remaining))
            first.locator = first.locator.copy(text: { $0.highlight = first.text })
            return [first] + segments.dropFirst(index + 1)
        }
        return []
    }

    private func coalescingWhitespace(in text: String) -> CoalescedText {
        let characters = Array(text)
        var result: [Character] = []
        var rawOffsets: [Int] = []
        var hasWhitespace = false
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                hasWhitespace = true
            } else {
                if hasWhitespace, !result.isEmpty {
                    result.append(" ")
                    rawOffsets.append(index)
                }
                result.append(character)
                rawOffsets.append(index + 1)
                hasWhitespace = false
            }
        }
        if hasWhitespace, !result.isEmpty {
            result.append(" ")
            rawOffsets.append(characters.count)
        }
        return CoalescedText(text: String(result), rawOffsets: rawOffsets)
    }

    private struct CoalescedText {
        let text: String
        let rawOffsets: [Int]

        func rawOffset(afterPrefix prefix: String) -> Int? {
            guard text.hasPrefix(prefix) else {
                return nil
            }
            return rawOffset(at: text.index(text.startIndex, offsetBy: prefix.count))
        }

        func rawOffset(at index: String.Index) -> Int {
            let offset = text.distance(from: text.startIndex, to: index)
            return offset == 0 ? 0 : rawOffsets[offset - 1]
        }
    }

    /// Splits a publication `ContentElement` item into the utterances to be spoken.
    private func utterances(for element: ContentElement) -> [Utterance] {
        func utterance(text: String, locator: Locator, language: Language? = nil) -> Utterance? {
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                return nil
            }

            return Utterance(
                text: text,
                locator: locator,
                language: language
                    // If the language is the same as the one declared globally in the publication,
                    // we omit it. This way, the app can customize the default language used in the
                    // configuration.
                    .takeIf { $0 != publication.metadata.language }
            )
        }

        switch element {
        case let element as TextContentElement:
            return element.segments
                .compactMap { segment in
                    utterance(text: segment.text, locator: segment.locator, language: segment.language)
                }

        case let element as TextualContentElement:
            guard let text = element.text.takeIf({ !$0.isEmpty }) else {
                return []
            }
            return Array(ofNotNil: utterance(text: text, locator: element.locator))

        default:
            return []
        }
    }

    // MARK: - Audio session

    private let audioSessionUser: AudioSessionUser

    private final class AudioSessionUser: ReadiumShared.AudioSessionUser {
        let audioConfiguration: AudioSession.Configuration

        init(config: AudioSession.Configuration) {
            audioConfiguration = config
        }

        func play() {}
    }
}

/// Bridges the operation-owned initial preparation task back to its caller
/// without making the caller's task the owner of preparation work.
private final class InitialPrefetchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

/// Holds a task independently of MainActor teardown so releasing
/// `PublicationSpeechSynthesizer` can cancel outstanding playback / look-ahead.
///
/// Only stores `Task` cancellation (thread-safe). Never wraps `@MainActor`
/// `cancelPrefetch()` — that must be invoked on the MainActor by the synthesizer.
private final class DetachedTaskLifecycleHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    func cancelTask() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    deinit {
        cancelTask()
    }
}

/// Thread-safe waiter list that outlives MainActor teardown of the synthesizer.
/// `deinit` resumes all pending continuations so cancelled playback cannot hang.
private final class ContinuationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !continuations.isEmpty
    }

    func append(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        continuations.append(continuation)
        lock.unlock()
    }

    func resumeAll() {
        lock.lock()
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    deinit {
        resumeAll()
    }
}

/// Weak box so look-ahead helpers can re-resolve the synthesizer after awaits
/// without the parameter list itself retaining it.
private final class WeakPublicationSpeechSynthesizer: @unchecked Sendable {
    weak var value: PublicationSpeechSynthesizer?

    init(_ value: PublicationSpeechSynthesizer?) {
        self.value = value
    }
}

private struct BufferedUtteranceGroup {
    let groupID: UUID
    let movementID: UUID
    let raw: ContentElement
    let prepared: ContentElement
    var utterances: [PublicationSpeechSynthesizer.Utterance]?
    var iteratorAdvanceCount: Int
    var isLeased: Bool
}

private enum Direction: Equatable {
    case forward, backward

    var opposite: Self {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        }
    }
}

private extension CursorList {
    mutating func next(_ direction: Direction) -> Element? {
        switch direction {
        case .forward:
            return next()
        case .backward:
            return previous()
        }
    }
}

private extension ContentIterator {
    func next(_ direction: Direction) async throws -> ContentElement? {
        switch direction {
        case .forward:
            return try await next()
        case .backward:
            return try await previous()
        }
    }
}
