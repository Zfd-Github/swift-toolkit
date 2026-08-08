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
    /// content load so releasing the owner mid-load can still complete deinit
    /// after the current load returns.
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
            let loaded: Bool
            if let self = weakSynthesizer.value {
                // Instance load may hold self across iterator awaits; capture is
                // limited to this call so speak/waiter paths stay weak-only.
                loaded = await self.loadNextUtterances(direction, generation: generation)
            } else {
                return nil
            }
            if !loaded {
                return nil
            }
        }
    }

    /// Loads the utterances for the next publication `ContentElement` item in the given `direction`.
    private func loadNextUtterances(
        _ direction: Direction,
        generation: UInt64
    ) async -> Bool {
        guard isCurrentOperation(generation) else { return false }
        if direction == .forward, !forwardGroups.isEmpty {
            guard let iterator = publicationIterator else { return false }
            let group = forwardGroups.removeFirst()
            func restoreGroup() {
                guard publicationIterator === iterator else { return }
                forwardGroups.insert(group, at: 0)
            }
            do {
                let nextUtterances: [Utterance]
                if let existing = group.utterances {
                    nextUtterances = existing
                } else {
                    nextUtterances = try tokenize(group.content)
                        .flatMap { utterances(for: $0) }
                    // Tokenizer may re-enter (config/stop/next). Re-validate
                    // before committing cursor state.
                    guard isCurrentOperation(generation, iterator: iterator) else {
                        restoreGroup()
                        return false
                    }
                }
                guard !nextUtterances.isEmpty else {
                    if forwardGroups.isEmpty {
                        trailingForwardAdvanceCount += group.iteratorAdvanceCount
                    } else {
                        forwardGroups[0] = forwardGroups[0]
                            .addingIteratorAdvanceCount(group.iteratorAdvanceCount)
                    }
                    return await loadNextUtterances(direction, generation: generation)
                }
                guard isCurrentOperation(generation, iterator: iterator) else {
                    restoreGroup()
                    return false
                }
                utterances = CursorList(list: nextUtterances, startIndex: 0)
                return true
            } catch {
                restoreGroup()
                log(.error, error)
                return false
            }
        }
        do {
            guard let iterator = publicationIterator else { return false }
            var nextUtterances: [Utterance] = []
            var usesPendingResult = false
            while nextUtterances.isEmpty {
                guard isCurrentOperation(generation, iterator: iterator) else {
                    return false
                }
                let content: ContentElement
                if
                    let pending = pendingIteratorResult,
                    pending.iterator === iterator
                {
                    if pending.direction == direction {
                        content = pending.content
                        usesPendingResult = true
                    } else {
                        guard try await iterator.next(pending.direction.opposite) != nil else {
                            return false
                        }
                        pendingIteratorResult = nil
                        guard isCurrentOperation(generation, iterator: iterator) else {
                            return false
                        }
                        continue
                    }
                } else {
                    pendingIteratorResult = nil
                    guard let nextContent = try await iterator.next(direction) else {
                        return false
                    }
                    guard isCurrentOperation(generation, iterator: iterator) else {
                        if publicationIterator === iterator {
                            pendingIteratorResult = (iterator, direction, nextContent)
                        }
                        return false
                    }
                    content = nextContent
                    usesPendingResult = false
                }

                nextUtterances = try tokenize(content)
                    .flatMap { utterances(for: $0) }
                // Re-validate after tokenizer reentrancy before committing.
                guard isCurrentOperation(generation, iterator: iterator) else {
                    if publicationIterator === iterator {
                        pendingIteratorResult = (iterator, direction, content)
                    }
                    return false
                }
                if usesPendingResult, nextUtterances.isEmpty {
                    pendingIteratorResult = nil
                }
            }

            guard isCurrentOperation(generation, iterator: iterator) else {
                return false
            }

            utterances = CursorList(
                list: nextUtterances,
                startIndex: {
                    switch direction {
                    case .forward: return 0
                    case .backward: return nextUtterances.count - 1
                    }
                }()
            )
            if direction == .forward {
                trailingForwardAdvanceCount = 0
            }
            if usesPendingResult {
                pendingIteratorResult = nil
            }

            return true

        } catch is CancellationError {
            return false
        } catch {
            log(.error, error)
            return false
        }
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

            // `tokenize` / `utterances(for:)` may re-enter the synthesizer (config
            // change, next/previous) and invalidate this look-ahead generation.
            // Capture results first, then re-validate before committing.
            let nextUtterances: [Utterance]
            do {
                nextUtterances = try synthesizer.tokenize(content)
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
                operationGeneration == synthesizer.operationGeneration,
                prefetchGeneration == synthesizer.prefetchGeneration
            else {
                // Superseded after tokenize: keep iterator accounting, drop stale
                // utterances produced under a previous configuration.
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
    /// epoch (config/stop/navigation) so callers abort instead of committing
    /// stale results or writing past a cleared buffer.
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

            let content = group.content
            let nextUtterances = try tokenize(content)
                .flatMap { utterances(for: $0) }

            // Tokenizer may re-enter (config / stop / next). Never write using a
            // captured index without re-validating identity and generations.
            guard
                !Task.isCancelled,
                operationGeneration == self.operationGeneration,
                prefetchGeneration == self.prefetchGeneration,
                forwardGroups.indices.contains(index),
                forwardGroups[index].utterances == nil
            else {
                return nil
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

    /// Splits a publication `ContentElement` item into smaller chunks using the provided tokenizer.
    ///
    /// This is used to split a paragraph into sentences, for example.
    func tokenize(_ element: ContentElement) throws -> [ContentElement] {
        guard
            let startText,
            var first = element as? TextContentElement
        else {
            let tokenizer = tokenizerFactory(config.defaultLanguage ?? publication.metadata.language)
            return try tokenizer(element)
        }
        defer { self.startText = nil }

        if let offset = textOffset(in: first, for: startText) {
            first.segments = trimming(first.segments, before: offset)
        }

        let tokenizer = tokenizerFactory(config.defaultLanguage ?? publication.metadata.language)
        return try tokenizer(first)
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
