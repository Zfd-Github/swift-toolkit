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
            forwardGroups = forwardGroups.map { $0.invalidatingPrefetch() }
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
        forwardPrefetchWaiters.resumeAll()
        playbackTaskLifecycle.cancelTask()
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
    // 1. Playback operation: identified by `operationGeneration`, owned by
    //    `currentTask` / `playbackTaskLifecycle`. Bumped on start(without prepared),
    //    stop, pause, next, previous. Task bodies must not strongly retain self
    //    across speak / wait / iterator / cancel-drain suspensions.
    // 2. Prefetch operation: identified by `prefetchGeneration`, owned by
    //    `forwardPrefetchTask` / `forwardPrefetchLifecycle` (+ optional
    //    `prefetchCancellationTask` while draining). Bumped on invalidate
    //    (config, stop, pause, navigation, failed look-ahead). Ready queue and
    //    in-flight forward work share this epoch.
    // 3. Iterator accounting: `publicationIterator` position, `pendingIteratorResult`,
    //    `forwardGroups` / `iteratorAdvanceCount` / `trailingForwardAdvanceCount`
    //    describe one logical cursor. A successful `next`/`previous` that returns
    //    an element (including after cancel) must update accounting before any
    //    generation-failure return.
    // 4. Tokenizer commit: after any user tokenizer call, re-check operation
    //    generation, prefetch/config epoch, iterator identity, and buffer index
    //    before writing `utterances` / `forwardGroups`. Locator trim
    //    (`applyingStartTextIfNeeded`) is applied once per content block and
    //    must not re-run on config-only retries.
    // 5. Waiters: `forwardPrefetchWaiters` outlives MainActor teardown; invalidate
    //    and deinit always `resumeAll()`.

    private var currentTask: Task<Void, Never>?
    private var forwardPrefetchTask: Task<Void, Never>?
    private var forwardPrefetchTaskID: UInt64 = 0
    /// Cancels playback / look-ahead tasks from `deinit` without MainActor hops.
    private let playbackTaskLifecycle = DetachedTaskLifecycleHandle()
    private let forwardPrefetchLifecycle = DetachedTaskLifecycleHandle()
    private var prefetchCancellationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var prefetchGeneration: UInt64 = 0
    private var prefetchRequestGeneration: UInt64 = 0
    private var prefetchCancellationGeneration: UInt64 = 0
    private struct ForwardPrefetch {
        let identifier: UUID
        let duration: TimeInterval
    }

    private var readyForwardPrefetches: [ForwardPrefetch] = []
    /// Continuations for `play` suspended on the next look-ahead ready/finished
    /// event. Held outside the synthesizer so deinit can still resume them.
    private let forwardPrefetchWaiters = ContinuationRegistry()
    private var engineStorage: TTSEngine?

    /// Whether `play` is suspended waiting for the next look-ahead item (or
    /// look-ahead end). Used by tests instead of fixed `Task.sleep` delays.
    var isWaitingForForwardPrefetchForTesting: Bool {
        forwardPrefetchWaiters.hasWaiters
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
        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        let oldPrefetchTask = invalidatePrefetch()
        operationGeneration &+= 1
        let generation = operationGeneration
        let prefetchGeneration = self.prefetchGeneration
        prefetchRequestGeneration &+= 1
        let prefetchRequestGeneration = self.prefetchRequestGeneration
        setStartText(from: startLocator)
        publicationIterator = nil
        return await withTaskCancellationHandler(
            operation: {
                await self.prefetchInitial(
                    from: startLocator,
                    oldCurrentTask: oldCurrentTask,
                    oldPrefetchTask: oldPrefetchTask,
                    operationGeneration: generation,
                    prefetchGeneration: prefetchGeneration,
                    prefetchRequestGeneration: prefetchRequestGeneration
                )
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.invalidatePrefetchIfCurrent(
                        operationGeneration: generation,
                        prefetchGeneration: prefetchGeneration,
                        prefetchRequestGeneration: prefetchRequestGeneration
                    )
                }
            }
        )
    }

    private func prefetchInitial(
        from startLocator: Locator?,
        oldCurrentTask: Task<Void, Never>?,
        oldPrefetchTask: Task<Void, Never>?,
        operationGeneration generation: UInt64,
        prefetchGeneration: UInt64,
        prefetchRequestGeneration: UInt64
    ) async -> Bool {
        defer {
            if Task.isCancelled {
                invalidatePrefetchIfCurrent(
                    operationGeneration: generation,
                    prefetchGeneration: prefetchGeneration,
                    prefetchRequestGeneration: prefetchRequestGeneration
                )
            }
        }
        await oldCurrentTask?.value
        await oldPrefetchTask?.value
        guard !Task.isCancelled else { return false }
        guard
            generation == operationGeneration,
            prefetchGeneration == self.prefetchGeneration
        else {
            return false
        }
        publicationIterator = publication.content(from: startLocator)?.iterator()
        guard let utterance = await Self.nextUtterance(
            weakSynthesizer: WeakPublicationSpeechSynthesizer(self),
            direction: .forward,
            generation: generation
        ) else { return false }
        guard !Task.isCancelled else { return false }
        guard
            generation == operationGeneration,
            prefetchGeneration == self.prefetchGeneration
        else {
            return false
        }
        guard let engine = engine as? TTSPrefetchingEngine else {
            return false
        }
        guard let prefetchDuration = await engine.prefetch(
            ttsUtterance(for: utterance),
            maximumDuration: Self.maximumSingleUtterancePrefetchDuration
        ),
        prefetchDuration.isFinite,
        prefetchDuration > 0,
        prefetchDuration <= Self.maximumSingleUtterancePrefetchDuration
        else { return false }
        guard !Task.isCancelled else { return false }
        guard
            generation == operationGeneration,
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

        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        if
            preparedStartLocator == startLocator,
            let utterance = preparedUtterance
        {
            preparedStartLocator = nil
            preparedUtterance = nil
            prefetchRequestGeneration &+= 1
            let generation = operationGeneration
            setCurrentTask(Task { [weak self] in
                await oldCurrentTask?.value
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
            })
            return
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        setStartText(from: startLocator)
        publicationIterator = nil
        setCurrentTask(Task { [weak self] in
            await oldCurrentTask?.value
            await oldPrefetchTask?.value
            let weakSynthesizer: WeakPublicationSpeechSynthesizer
            if let self {
                guard generation == self.operationGeneration else { return }
                self.publicationIterator = self.publication.content(from: startLocator)?.iterator()
                weakSynthesizer = WeakPublicationSpeechSynthesizer(self)
            } else {
                return
            }
            await Self.continuePlaying(
                weakSynthesizer: weakSynthesizer,
                utterance: nil,
                generation: generation
            )
        })
    }

    private func setCurrentTask(_ task: Task<Void, Never>) {
        currentTask = task
        playbackTaskLifecycle.setTask(task)
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
        currentTask?.cancel()
        currentTask = nil
        playbackTaskLifecycle.clearTask()
        operationGeneration &+= 1
        invalidatePrefetch()
        state = .stopped
        publicationIterator = nil
    }

    /// Interrupts a played utterance.
    ///
    /// Use `resume()` to restart the playback from the same utterance.
    public func pause() {
        currentTask?.cancel()
        currentTask = nil
        playbackTaskLifecycle.clearTask()
        operationGeneration &+= 1
        invalidatePrefetch()
        if case let .playing(utterance, range: _) = state {
            state = .paused(utterance)
        }
    }

    /// Resumes an utterance interrupted with `pause()`.
    public func resume() {
        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        if case let .paused(utterance) = state {
            operationGeneration &+= 1
            let generation = operationGeneration
            let oldPrefetchTask = invalidatePrefetch()
            setCurrentTask(Task { [weak self] in
                await oldCurrentTask?.value
                await oldPrefetchTask?.value
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
            })
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
        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        setCurrentTask(Task { [weak self] in
            await oldCurrentTask?.value
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
        })
    }

    /// Skips to the next utterance.
    public func next() {
        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        setCurrentTask(Task { [weak self] in
            await oldCurrentTask?.value
            await oldPrefetchTask?.value
            let weakSynthesizer: WeakPublicationSpeechSynthesizer
            let needsRollback: Bool
            if let self {
                guard generation == self.operationGeneration else { return }
                needsRollback = self.requiresForwardBufferRollback
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
        })
    }

    /// `Content.Iterator` used to iterate through the `publication`.
    private var publicationIterator: ContentIterator? {
        didSet {
            utterances = CursorList()
            forwardGroups = []
            trailingForwardAdvanceCount = 0
            requiresForwardBufferRollback = false
            pendingIteratorResult = nil
        }
    }

    private var startText: Locator.Text?
    private var preparedStartLocator: Locator?
    private var preparedUtterance: Utterance?

    /// Utterances for the current publication `ContentElement` item.
    private var utterances: CursorList<Utterance> = CursorList()
    private var forwardGroups: [BufferedUtteranceGroup] = []
    private var trailingForwardAdvanceCount = 0
    private var requiresForwardBufferRollback = false
    private var pendingIteratorResult: (
        iterator: ContentIterator,
        direction: Direction,
        content: ContentElement
    )?

    private func isCurrentOperation(
        _ generation: UInt64,
        iterator: ContentIterator? = nil
    ) -> Bool {
        !Task.isCancelled &&
            generation == operationGeneration &&
            (iterator == nil || publicationIterator === iterator)
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
                    if let self = weakSynthesizer.value, generation == self.operationGeneration {
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
            guard !Task.isCancelled, generation == self.operationGeneration else {
                return false
            }
            prepared = (self.engine, self.ttsUtterance(for: utterance))
            self.state = .playing(utterance, range: nil)
            // Delegate may stop/cancel synchronously from stateDidChange.
            guard !Task.isCancelled, generation == self.operationGeneration else {
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
                guard generation == self.operationGeneration else { return }

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
                guard generation == self.operationGeneration else { return }
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
            if let self = weakSynthesizer.value {
                guard !Task.isCancelled, generation == self.operationGeneration else {
                    return false
                }
                shouldWait = self.readyForwardPrefetches.isEmpty && self.forwardPrefetchTask != nil
                prefetchGeneration = self.prefetchGeneration
            } else {
                return false
            }

            if shouldWait {
                await waitUntilNextForwardReadyOrFinished(
                    weakSynthesizer: weakSynthesizer,
                    operationGeneration: generation,
                    prefetchGeneration: prefetchGeneration
                )
            }

            // Drain cancellation without retaining self across the await.
            let cancellation: Task<Void, Never>?
            if let self = weakSynthesizer.value {
                guard !Task.isCancelled, generation == self.operationGeneration else {
                    return false
                }
                cancellation = self.prefetchCancellationTask
            } else {
                return false
            }
            await cancellation?.value

            if let self = weakSynthesizer.value {
                guard !Task.isCancelled, generation == self.operationGeneration else {
                    return false
                }
                if !self.readyForwardPrefetches.isEmpty {
                    self.readyForwardPrefetches.removeFirst()
                }
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
    /// `iterator.next` cannot re-form self → currentTask → self.
    private static func loadNextUtterances(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        direction: Direction,
        generation: UInt64
    ) async -> Bool {
        while true {
            if direction == .forward {
                enum GroupStep {
                    case use(BufferedUtteranceGroup, ContentIterator)
                    case none
                }
                let step: GroupStep
                if let self = weakSynthesizer.value {
                    guard self.isCurrentOperation(generation) else { return false }
                    if self.forwardGroups.isEmpty {
                        step = .none
                    } else if let iterator = self.publicationIterator {
                        step = .use(self.forwardGroups.removeFirst(), iterator)
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
        group: BufferedUtteranceGroup,
        iterator: ContentIterator,
        generation: UInt64
    ) async -> ForwardGroupConsumeResult {
        func restorePending(_ utterances: [Utterance]?) {
            guard let self = weakSynthesizer.value, self.publicationIterator === iterator else {
                return
            }
            self.forwardGroups.insert(
                BufferedUtteranceGroup(
                    content: group.content,
                    utterances: utterances,
                    iteratorAdvanceCount: group.iteratorAdvanceCount
                ),
                at: 0
            )
        }

        if let existing = group.utterances {
            guard let self = weakSynthesizer.value else { return .failed }
            guard self.isCurrentOperation(generation, iterator: iterator) else {
                restorePending(existing)
                return .failed
            }
            if existing.isEmpty {
                if self.forwardGroups.isEmpty {
                    self.trailingForwardAdvanceCount += group.iteratorAdvanceCount
                } else {
                    self.forwardGroups[0] = self.forwardGroups[0]
                        .addingIteratorAdvanceCount(group.iteratorAdvanceCount)
                }
                return .emptyContinue
            }
            self.utterances = CursorList(list: existing, startIndex: 0)
            return .ready
        }

        // Apply locator trim once, then re-run only the config-sensitive tokenizer
        // if config re-enters. Bounded retries prevent MainActor livelock.
        let preparedContent: ContentElement
        if let self = weakSynthesizer.value {
            guard self.isCurrentOperation(generation, iterator: iterator) else {
                restorePending(nil)
                return .failed
            }
            preparedContent = self.applyingStartTextIfNeeded(group.content)
        } else {
            return .failed
        }

        var configRetries = 0
        while true {
            let prefetchEpoch: UInt64
            let tokenized: [Utterance]
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    restorePending(nil)
                    return .failed
                }
                prefetchEpoch = self.prefetchGeneration
                do {
                    tokenized = try self.tokenizePrepared(preparedContent)
                        .flatMap { self.utterances(for: $0) }
                } catch {
                    if let self = weakSynthesizer.value, self.publicationIterator === iterator {
                        self.forwardGroups.insert(group, at: 0)
                        self.log(.error, error)
                    }
                    return .failed
                }
            } else {
                return .failed
            }

            guard let self = weakSynthesizer.value else { return .failed }
            guard self.isCurrentOperation(generation, iterator: iterator) else {
                restorePending(nil)
                return .failed
            }
            // Config change only bumps prefetchGeneration — must not commit stale tokens.
            if prefetchEpoch != self.prefetchGeneration {
                configRetries += 1
                if configRetries > Self.maximumConfigTokenizeRetries {
                    // Leave group pending for a later epoch; do not spin on MainActor.
                    restorePending(nil)
                    return .failed
                }
                continue
            }

            if tokenized.isEmpty {
                if self.forwardGroups.isEmpty {
                    self.trailingForwardAdvanceCount += group.iteratorAdvanceCount
                } else {
                    self.forwardGroups[0] = self.forwardGroups[0]
                        .addingIteratorAdvanceCount(group.iteratorAdvanceCount)
                }
                return .emptyContinue
            }

            self.utterances = CursorList(list: tokenized, startIndex: 0)
            return .ready
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
            guard let current = self.publicationIterator else { return false }
            iterator = current
        } else {
            return false
        }

        var nextUtterances: [Utterance] = []
        var usesPendingResult = false

        while nextUtterances.isEmpty {
            enum ContentLoad {
                case ready(ContentElement, usesPending: Bool)
                case fetch
                /// Opposite step to undo a pending advance from a cancelled load.
                case opposite(undoDirection: Direction, expectedPendingDirection: Direction)
            }

            let load: ContentLoad
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }
                if
                    let pending = self.pendingIteratorResult,
                    pending.iterator === iterator
                {
                    if pending.direction == direction {
                        load = .ready(pending.content, usesPending: true)
                    } else {
                        load = .opposite(
                            undoDirection: pending.direction.opposite,
                            expectedPendingDirection: pending.direction
                        )
                    }
                } else {
                    self.pendingIteratorResult = nil
                    load = .fetch
                }
            } else {
                return false
            }

            let content: ContentElement
            switch load {
            case let .ready(readyContent, usesPending):
                content = readyContent
                usesPendingResult = usesPending

            case let .opposite(undoDirection, expectedPendingDirection):
                // Iterator may return the element even when the task is cancelled.
                let moved: ContentElement?
                do {
                    moved = try await iterator.next(undoDirection)
                } catch {
                    if !(error is CancellationError), let self = weakSynthesizer.value {
                        self.log(.error, error)
                    }
                    return false
                }
                guard moved != nil else { return false }

                // Accounting first: clear pending only if it still matches this
                // undo, then check generation. Cursor already moved.
                if let self = weakSynthesizer.value {
                    if
                        let pending = self.pendingIteratorResult,
                        pending.iterator === iterator,
                        pending.direction == expectedPendingDirection
                    {
                        self.pendingIteratorResult = nil
                    }
                }

                guard let self = weakSynthesizer.value else { return false }
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }
                continue

            case .fetch:
                let nextContent: ContentElement?
                do {
                    nextContent = try await iterator.next(direction)
                } catch {
                    if !(error is CancellationError), let self = weakSynthesizer.value {
                        self.log(.error, error)
                    }
                    return false
                }
                guard let nextContent else { return false }
                guard let self = weakSynthesizer.value else { return false }
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    if self.publicationIterator === iterator {
                        self.pendingIteratorResult = (iterator, direction, nextContent)
                    }
                    return false
                }
                content = nextContent
                usesPendingResult = false
            }

            // Locator trim once per content; config-sensitive tokenize may retry
            // a bounded number of times without spinning MainActor forever.
            let preparedContent: ContentElement
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    if self.publicationIterator === iterator {
                        self.pendingIteratorResult = (iterator, direction, content)
                    }
                    return false
                }
                preparedContent = self.applyingStartTextIfNeeded(content)
            } else {
                return false
            }

            var configRetries = 0
            while true {
                let prefetchEpoch: UInt64
                let tokenized: [Utterance]
                if let self = weakSynthesizer.value {
                    guard self.isCurrentOperation(generation, iterator: iterator) else {
                        if self.publicationIterator === iterator {
                            self.pendingIteratorResult = (iterator, direction, content)
                        }
                        return false
                    }
                    prefetchEpoch = self.prefetchGeneration
                    do {
                        tokenized = try self.tokenizePrepared(preparedContent)
                            .flatMap { self.utterances(for: $0) }
                    } catch {
                        if let self = weakSynthesizer.value {
                            self.log(.error, error)
                        }
                        return false
                    }
                } else {
                    return false
                }

                guard let self = weakSynthesizer.value else { return false }
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    if self.publicationIterator === iterator {
                        self.pendingIteratorResult = (iterator, direction, content)
                    }
                    return false
                }
                if prefetchEpoch != self.prefetchGeneration {
                    configRetries += 1
                    if configRetries > Self.maximumConfigTokenizeRetries {
                        // Abort this load; content preserved via pending if needed.
                        if self.publicationIterator === iterator {
                            self.pendingIteratorResult = (iterator, direction, content)
                        }
                        return false
                    }
                    continue
                }

                nextUtterances = tokenized
                if usesPendingResult, nextUtterances.isEmpty {
                    self.pendingIteratorResult = nil
                }
                break
            }
        }

        guard let self = weakSynthesizer.value else { return false }
        guard self.isCurrentOperation(generation, iterator: iterator) else {
            return false
        }

        self.utterances = CursorList(
            list: nextUtterances,
            startIndex: {
                switch direction {
                case .forward: return 0
                case .backward: return nextUtterances.count - 1
                }
            }()
        )
        if direction == .forward {
            self.trailingForwardAdvanceCount = 0
        }
        if usesPendingResult {
            self.pendingIteratorResult = nil
        }
        return true
    }

    private func startForwardPrefetch(
        generation: UInt64,
        prefetchGeneration requestedPrefetchGeneration: UInt64? = nil
    ) {
        guard
            forwardPrefetchTask == nil,
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
        let cancellationTask = prefetchCancellationTask
        forwardPrefetchTaskID &+= 1
        let taskID = forwardPrefetchTaskID
        let maximumPrefetchDuration = Self.maximumPrefetchDuration
        let maximumSingleDuration = Self.maximumSingleUtterancePrefetchDuration
        // Unstructured, MainActor-inherited task. Re-resolve `self` weakly around
        // every suspension (`iterator.next` and `engine.prefetch`) so neither a
        // gated content load nor multi-second neural synth pins the synthesizer
        // via self → task → self.
        let task = Task { [weak self] in
            await cancellationTask?.value
            defer { self?.finishForwardPrefetch(taskID: taskID) }

            var candidates: [Utterance] = []
            var candidateIndex = 0
            var prefetchedIdentifiers = Set<UUID>()
            var duration: TimeInterval = 0

            if let self {
                guard
                    generation == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration
                else {
                    return
                }
                // Re-tokenize config-invalidated groups (`utterances == nil`) in
                // order before reading further from the iterator — never skip
                // over pending buffer slots to later content.
                do {
                    guard let collected = try self.collectForwardPrefetchCandidates(
                        operationGeneration: generation,
                        prefetchGeneration: prefetchGeneration
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
                    prefetchGeneration == self.prefetchGeneration
                else {
                    return
                }
                prefetchedIdentifiers = Set(self.readyForwardPrefetches.map(\.identifier))
                duration = self.readyForwardPrefetches.reduce(into: 0) { $0 += $1.duration }
            } else {
                return
            }

            while duration < maximumPrefetchDuration {
                if candidateIndex == candidates.count {
                    let loaded = await Self.loadNextForwardGroup(
                        weakSynthesizer: WeakPublicationSpeechSynthesizer(self),
                        operationGeneration: generation,
                        prefetchGeneration: prefetchGeneration
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
                        prefetchGeneration == self.prefetchGeneration
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

                guard let self else { return }
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
                guard
                    !Task.isCancelled,
                    generation == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration
                else {
                    return
                }
                self.readyForwardPrefetches.append(
                    ForwardPrefetch(
                        identifier: prepared.identifier,
                        duration: prefetchedDuration
                    )
                )
                duration += prefetchedDuration
                // Wake consumers waiting for the next item only — do not make
                // them await the rest of the waterline.
                self.notifyForwardPrefetchWaiters()
                // Let resumed waiters run on MainActor before more look-ahead.
                await Task.yield()
            }
        }
        forwardPrefetchTask = task
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
        prefetchGeneration: UInt64
    ) async -> ForwardGroupLoadResult {
        let iterator: ContentIterator
        var advanceCount: Int
        if let synthesizer = weakSynthesizer.value {
            guard
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration,
                let currentIterator = synthesizer.publicationIterator
            else {
                return .finished
            }
            iterator = currentIterator
            advanceCount = synthesizer.trailingForwardAdvanceCount
            synthesizer.trailingForwardAdvanceCount = 0
        } else {
            return .finished
        }

        var contentToPreserve: ContentElement?
        while true {
            if let synthesizer = weakSynthesizer.value {
                guard
                    synthesizer.publicationIterator === iterator,
                    !Task.isCancelled,
                    operationGeneration == synthesizer.operationGeneration,
                    prefetchGeneration == synthesizer.prefetchGeneration
                else {
                    if synthesizer.publicationIterator === iterator {
                        synthesizer.trailingForwardAdvanceCount = advanceCount
                    }
                    return .finished
                }
            } else {
                return .finished
            }

            // No strong synthesizer across the iterator suspension.
            let content: ContentElement?
            do {
                content = try await iterator.next()
            } catch is CancellationError {
                if let synthesizer = weakSynthesizer.value,
                   synthesizer.publicationIterator === iterator
                {
                    if let preserved = contentToPreserve {
                        synthesizer.forwardGroups.append(
                            BufferedUtteranceGroup(
                                content: preserved,
                                utterances: nil,
                                iteratorAdvanceCount: advanceCount
                            )
                        )
                    } else {
                        synthesizer.trailingForwardAdvanceCount = advanceCount
                    }
                }
                return .finished
            } catch {
                if let synthesizer = weakSynthesizer.value {
                    synthesizer.log(.error, error)
                    if let preserved = contentToPreserve, synthesizer.publicationIterator === iterator {
                        synthesizer.forwardGroups.append(
                            BufferedUtteranceGroup(
                                content: preserved,
                                utterances: nil,
                                iteratorAdvanceCount: advanceCount
                            )
                        )
                    } else if synthesizer.publicationIterator === iterator {
                        synthesizer.trailingForwardAdvanceCount = advanceCount
                    }
                }
                return .finished
            }

            guard let content else {
                if let synthesizer = weakSynthesizer.value,
                   synthesizer.publicationIterator === iterator
                {
                    synthesizer.trailingForwardAdvanceCount = advanceCount
                }
                return .finished
            }
            advanceCount += 1
            contentToPreserve = content

            // Re-check after the suspension: cancel/config may have invalidated
            // look-ahead while `next()` was in flight. Do not tokenize/commit
            // into a superseded generation (avoids racing playNext on the iterator).
            guard let synthesizer = weakSynthesizer.value else { return .finished }
            guard
                synthesizer.publicationIterator === iterator,
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration
            else {
                if synthesizer.publicationIterator === iterator {
                    synthesizer.forwardGroups.append(
                        BufferedUtteranceGroup(
                            content: content,
                            utterances: nil,
                            iteratorAdvanceCount: advanceCount
                        )
                    )
                }
                return .finished
            }

            // Locator trim once; config-sensitive tokenize with bounded epoch retries.
            let prepared = synthesizer.applyingStartTextIfNeeded(content)
            var configRetries = 0
            let nextUtterances: [Utterance]
            while true {
                let epochAtStart = synthesizer.prefetchGeneration
                let tokenized: [Utterance]
                do {
                    tokenized = try synthesizer.tokenizePrepared(prepared)
                        .flatMap { synthesizer.utterances(for: $0) }
                } catch {
                    if let synthesizer = weakSynthesizer.value {
                        synthesizer.log(.error, error)
                        if synthesizer.publicationIterator === iterator {
                            synthesizer.forwardGroups.append(
                                BufferedUtteranceGroup(
                                    content: content,
                                    utterances: nil,
                                    iteratorAdvanceCount: advanceCount
                                )
                            )
                        }
                    }
                    return .finished
                }

                guard let synthesizer = weakSynthesizer.value else { return .finished }
                guard
                    synthesizer.publicationIterator === iterator,
                    !Task.isCancelled,
                    operationGeneration == synthesizer.operationGeneration
                else {
                    if synthesizer.publicationIterator === iterator {
                        synthesizer.forwardGroups.append(
                            BufferedUtteranceGroup(
                                content: content,
                                utterances: nil,
                                iteratorAdvanceCount: advanceCount
                            )
                        )
                    }
                    return .finished
                }

                if epochAtStart != synthesizer.prefetchGeneration ||
                    prefetchGeneration != synthesizer.prefetchGeneration
                {
                    configRetries += 1
                    if configRetries > Self.maximumConfigTokenizeRetries ||
                        prefetchGeneration != synthesizer.prefetchGeneration
                    {
                        // Superseded look-ahead epoch — keep accounting, drop tokens.
                        synthesizer.forwardGroups.append(
                            BufferedUtteranceGroup(
                                content: content,
                                utterances: nil,
                                iteratorAdvanceCount: advanceCount
                            )
                        )
                        return .finished
                    }
                    continue
                }

                nextUtterances = tokenized
                break
            }

            guard let synthesizer = weakSynthesizer.value else { return .finished }
            guard
                synthesizer.publicationIterator === iterator,
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration
            else {
                if synthesizer.publicationIterator === iterator {
                    synthesizer.forwardGroups.append(
                        BufferedUtteranceGroup(
                            content: content,
                            utterances: nil,
                            iteratorAdvanceCount: advanceCount
                        )
                    )
                }
                return .finished
            }

            if !nextUtterances.isEmpty {
                let group = BufferedUtteranceGroup(
                    content: content,
                    utterances: nextUtterances,
                    iteratorAdvanceCount: advanceCount
                )
                synthesizer.forwardGroups.append(group)
                return .group(nextUtterances)
            }

            guard
                synthesizer.publicationIterator === iterator,
                !Task.isCancelled,
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration
            else {
                synthesizer.trailingForwardAdvanceCount = advanceCount
                return .finished
            }
        }
    }

    /// Marks the forward task finished and wakes waiters. No-ops when superseded
    /// by `invalidatePrefetch` (task id mismatch).
    private func finishForwardPrefetch(taskID: UInt64) {
        guard taskID == forwardPrefetchTaskID else {
            return
        }
        forwardPrefetchTask = nil
        forwardPrefetchLifecycle.clearTask()
        notifyForwardPrefetchWaiters()
    }

    private func notifyForwardPrefetchWaiters() {
        forwardPrefetchWaiters.resumeAll()
    }

    /// Builds look-ahead candidates from the current cursor and `forwardGroups`,
    /// re-tokenizing any groups whose utterances were cleared by a config change.
    /// Does not advance the publication iterator.
    ///
    /// Returns `nil` when reentrant tokenizer work invalidated this look-ahead
    /// epoch (stop/navigation or superseded prefetch generation) so callers
    /// abort instead of committing stale results or writing past a cleared buffer.
    private func collectForwardPrefetchCandidates(
        operationGeneration: UInt64,
        prefetchGeneration: UInt64
    ) throws -> [Utterance]? {
        var candidates = Array(utterances.elementsAfterCurrent())
        var index = 0
        while index < forwardGroups.count {
            let group = forwardGroups[index]
            if let existing = group.utterances {
                candidates.append(contentsOf: existing)
                index += 1
                continue
            }

            // Capture epoch before tokenize; config reentry only bumps prefetchGeneration.
            let content = group.content
            // Trim once per group content; config-only retries re-run tokenizer.
            let prepared = applyingStartTextIfNeeded(content)
            var configRetries = 0
            let nextUtterances: [Utterance]
            while true {
                let epochAtStart = self.prefetchGeneration
                let tokenized = try tokenizePrepared(prepared)
                    .flatMap { utterances(for: $0) }

                guard
                    !Task.isCancelled,
                    operationGeneration == self.operationGeneration,
                    forwardGroups.indices.contains(index),
                    forwardGroups[index].utterances == nil
                else {
                    return nil
                }

                if epochAtStart != self.prefetchGeneration ||
                    prefetchGeneration != self.prefetchGeneration
                {
                    configRetries += 1
                    if configRetries > Self.maximumConfigTokenizeRetries {
                        return nil
                    }
                    // Caller epoch may be stale; abort so a newer task restarts.
                    if prefetchGeneration != self.prefetchGeneration {
                        return nil
                    }
                    continue
                }

                nextUtterances = tokenized
                break
            }

            forwardGroups[index] = BufferedUtteranceGroup(
                content: forwardGroups[index].content,
                utterances: nextUtterances,
                iteratorAdvanceCount: forwardGroups[index].iteratorAdvanceCount
            )
            candidates.append(contentsOf: nextUtterances)
            index += 1
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
        prefetchGeneration: UInt64
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let self = weakSynthesizer.value else {
                    continuation.resume()
                    return
                }
                guard
                    !Task.isCancelled,
                    operationGeneration == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration
                else {
                    continuation.resume()
                    return
                }
                if !self.readyForwardPrefetches.isEmpty || self.forwardPrefetchTask == nil {
                    continuation.resume()
                    return
                }
                self.forwardPrefetchWaiters.append(continuation)
            }
        } onCancel: {
            // Best-effort: if the synthesizer still exists, wake its waiters.
            // Registry deinit also resumes any leftovers after synthesizer release.
            Task { @MainActor in
                weakSynthesizer.value?.forwardPrefetchWaiters.resumeAll()
            }
        }
    }

    private func invalidatePrefetchIfCurrent(
        operationGeneration: UInt64,
        prefetchGeneration: UInt64,
        prefetchRequestGeneration: UInt64
    ) {
        guard
            operationGeneration == self.operationGeneration,
            prefetchGeneration == self.prefetchGeneration,
            prefetchRequestGeneration == self.prefetchRequestGeneration
        else {
            return
        }
        invalidatePrefetch()
    }

    @discardableResult
    private func invalidatePrefetch() -> Task<Void, Never>? {
        prefetchGeneration &+= 1
        forwardPrefetchTaskID &+= 1
        readyForwardPrefetches = []
        preparedStartLocator = nil
        preparedUtterance = nil
        let task = forwardPrefetchTask
        forwardPrefetchTask = nil
        // Drop lifecycle ownership before cancel so deinit of a racing release
        // does not double-cancel after we finish sequencing below.
        forwardPrefetchLifecycle.clearTask()
        task?.cancel()
        // Always wake waiters: stop/pause/next/previous/config must not deadlock
        // on a pending forward-ready continuation.
        notifyForwardPrefetchWaiters()
        guard
            task != nil ||
            engineStorage is TTSPrefetchingEngine ||
            prefetchCancellationTask != nil
        else {
            return nil
        }
        // Still on MainActor here — call the isolated engine API directly.
        let engine = engineStorage as? TTSPrefetchingEngine
        engine?.cancelPrefetch()
        let previousCancellation = prefetchCancellationTask
        prefetchCancellationGeneration &+= 1
        let cancellationGeneration = prefetchCancellationGeneration
        let cancellation = Task { [weak self] in
            await previousCancellation?.value
            await task?.value
            guard
                let self,
                cancellationGeneration == self.prefetchCancellationGeneration
            else {
                return
            }
            self.prefetchCancellationTask = nil
        }
        prefetchCancellationTask = cancellation
        return cancellation
    }

    private static func rollbackForwardBuffer(
        weakSynthesizer: WeakPublicationSpeechSynthesizer,
        generation: UInt64
    ) async {
        let iterator: ContentIterator
        let advanceCount: Int
        if let self = weakSynthesizer.value {
            guard self.isCurrentOperation(generation) else { return }
            advanceCount = self.forwardGroups.reduce(self.trailingForwardAdvanceCount) {
                $0 + $1.iteratorAdvanceCount
            }
            self.forwardGroups = []
            self.trailingForwardAdvanceCount = 0
            guard let current = self.publicationIterator else { return }
            iterator = current
        } else {
            return
        }

        var completed = 0
        for _ in 0 ..< advanceCount {
            if let self = weakSynthesizer.value {
                guard self.isCurrentOperation(generation, iterator: iterator) else {
                    if self.publicationIterator === iterator {
                        self.trailingForwardAdvanceCount = advanceCount - completed
                        self.requiresForwardBufferRollback = (advanceCount - completed) > 0
                    }
                    return
                }
            } else {
                return
            }

            let moved: ContentElement?
            do {
                moved = try await iterator.previous()
            } catch is CancellationError {
                if let self = weakSynthesizer.value, self.publicationIterator === iterator {
                    self.trailingForwardAdvanceCount = advanceCount - completed
                    self.requiresForwardBufferRollback = (advanceCount - completed) > 0
                }
                return
            } catch {
                if let self = weakSynthesizer.value {
                    if self.publicationIterator === iterator {
                        self.trailingForwardAdvanceCount = advanceCount - completed
                        self.requiresForwardBufferRollback = (advanceCount - completed) > 0
                    }
                    self.log(.error, error)
                }
                return
            }

            guard moved != nil else {
                if let self = weakSynthesizer.value, self.publicationIterator === iterator {
                    self.trailingForwardAdvanceCount = advanceCount - completed
                    self.requiresForwardBufferRollback = (advanceCount - completed) > 0
                }
                return
            }
            completed += 1
        }

        if let self = weakSynthesizer.value, self.isCurrentOperation(generation, iterator: iterator) {
            self.requiresForwardBufferRollback = false
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
    let content: ContentElement
    let utterances: [PublicationSpeechSynthesizer.Utterance]?
    let iteratorAdvanceCount: Int

    func invalidatingPrefetch() -> Self {
        .init(content: content, utterances: nil, iteratorAdvanceCount: iteratorAdvanceCount)
    }

    func addingIteratorAdvanceCount(_ count: Int) -> Self {
        .init(content: content, utterances: utterances, iteratorAdvanceCount: iteratorAdvanceCount + count)
    }
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
