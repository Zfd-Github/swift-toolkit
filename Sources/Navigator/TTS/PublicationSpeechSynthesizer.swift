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
    private var engineStorage: TTSEngine?

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
        guard let utterance = await nextUtterance(.forward, generation: generation) else { return false }
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
            currentTask = Task {
                await oldCurrentTask?.value
                guard generation == self.operationGeneration else { return }
                await play(utterance, generation: generation)
            }
            return
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        setStartText(from: startLocator)
        publicationIterator = nil
        currentTask = Task {
            await oldCurrentTask?.value
            await oldPrefetchTask?.value
            guard generation == self.operationGeneration else { return }
            self.publicationIterator = self.publication.content(from: startLocator)?.iterator()
            await playNextUtterance(.forward, generation: generation)
        }
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
            currentTask = Task {
                await oldCurrentTask?.value
                await oldPrefetchTask?.value
                guard generation == self.operationGeneration else { return }
                await play(utterance, generation: generation)
            }
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
        currentTask = Task {
            await oldCurrentTask?.value
            await oldPrefetchTask?.value
            guard generation == self.operationGeneration else { return }
            await rollbackForwardBuffer(generation: generation)
            guard generation == self.operationGeneration else { return }
            await playNextUtterance(.backward, generation: generation)
        }
    }

    /// Skips to the next utterance.
    public func next() {
        let oldCurrentTask = currentTask
        oldCurrentTask?.cancel()
        operationGeneration &+= 1
        let generation = operationGeneration
        let oldPrefetchTask = invalidatePrefetch()
        currentTask = Task {
            await oldCurrentTask?.value
            await oldPrefetchTask?.value
            guard generation == self.operationGeneration else { return }
            if requiresForwardBufferRollback {
                await rollbackForwardBuffer(generation: generation)
                guard generation == self.operationGeneration else { return }
            }
            await playNextUtterance(.forward, generation: generation)
        }
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

    /// Plays the next utterance in the given `direction`.
    private func playNextUtterance(
        _ direction: Direction,
        generation: UInt64
    ) async {
        guard let utterance = await nextUtterance(direction, generation: generation) else {
            guard generation == operationGeneration else { return }
            state = .stopped
            return
        }
        guard generation == operationGeneration else { return }
        await play(utterance, generation: generation)
    }

    /// Plays the given `utterance` with the TTS `engine`.
    private func play(
        _ utterance: Utterance,
        generation: UInt64
    ) async {
        let ttsUtterance = ttsUtterance(for: utterance)
        state = .playing(utterance, range: nil)
        guard !Task.isCancelled, generation == operationGeneration else {
            return
        }
        var didStartPrefetch = false

        let result = await engine.speak(
            ttsUtterance,
            onSpeakRange: { [weak self] range in
                guard let self = self else {
                    return
                }
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
                if !didStartPrefetch {
                    didStartPrefetch = true
                    self.startForwardPrefetch(generation: generation)
                }
            }
        )

        guard
            !Task.isCancelled,
            generation == operationGeneration
        else {
            return
        }

        switch result {
        case .success:
            let canContinueImmediately = !readyForwardPrefetches.isEmpty
            if canContinueImmediately {
                readyForwardPrefetches.removeFirst()
            } else {
                let oldPrefetchTask = invalidatePrefetch()
                await oldPrefetchTask?.value
            }
            guard generation == operationGeneration else { return }
            await playNextUtterance(.forward, generation: generation)
        case let .failure(error):
            invalidatePrefetch()
            state = .paused(utterance)
            delegate?.publicationSpeechSynthesizer(self, utterance: utterance, didFailWithError: .engine(error))
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

    /// Gets the next utterance in the given `direction`, or null when reaching the beginning or the end.
    private func nextUtterance(
        _ direction: Direction,
        generation: UInt64
    ) async -> Utterance? {
        guard isCurrentOperation(generation) else { return nil }
        guard let utterance = utterances.next(direction) else {
            if await loadNextUtterances(direction, generation: generation) {
                return await nextUtterance(direction, generation: generation)
            }
            return nil
        }
        return utterance
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
                let nextUtterances = try group.utterances ?? tokenize(group.content)
                    .flatMap { utterances(for: $0) }
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
        forwardPrefetchTask = Task { [weak self] in
            guard let self else { return }
            await cancellationTask?.value
            guard
                operationGeneration == self.operationGeneration,
                prefetchGeneration == self.prefetchGeneration
            else {
                return
            }
            await self.prefetchForward(
                operationGeneration: generation,
                prefetchGeneration: prefetchGeneration
            )
            guard
                operationGeneration == self.operationGeneration,
                prefetchGeneration == self.prefetchGeneration
            else {
                return
            }
            self.forwardPrefetchTask = nil
        }
    }

    private func prefetchForward(
        operationGeneration: UInt64,
        prefetchGeneration: UInt64
    ) async {
        guard let engine = engine as? TTSPrefetchingEngine else { return }
        var candidates = Array(utterances.elementsAfterCurrent()) +
            forwardGroups.flatMap { $0.utterances ?? [] }
        var candidateIndex = 0
        var prefetchedIdentifiers = Set(readyForwardPrefetches.map(\.identifier))
        var duration = readyForwardPrefetches.reduce(into: 0) { $0 += $1.duration }

        while duration < Self.maximumPrefetchDuration {
            guard
                !Task.isCancelled,
                operationGeneration == self.operationGeneration,
                prefetchGeneration == self.prefetchGeneration
            else {
                return
            }

            if candidateIndex == candidates.count {
                guard
                    let group = await loadForwardGroupForPrefetch(
                        operationGeneration: operationGeneration,
                        prefetchGeneration: prefetchGeneration
                    )
                else {
                    return
                }
                guard
                    !Task.isCancelled,
                    operationGeneration == self.operationGeneration,
                    prefetchGeneration == self.prefetchGeneration
                else {
                    return
                }
                candidates.append(contentsOf: group.utterances ?? [])
            }

            let utterance = candidates[candidateIndex]
            candidateIndex += 1
            guard prefetchedIdentifiers.insert(utterance.prefetchIdentifier).inserted else {
                continue
            }
            guard let prefetchedDuration = await engine.prefetch(
                ttsUtterance(for: utterance),
                maximumDuration: Self.maximumSingleUtterancePrefetchDuration
            ) else {
                return
            }
            guard
                prefetchedDuration.isFinite,
                prefetchedDuration > 0,
                prefetchedDuration <= Self.maximumSingleUtterancePrefetchDuration
            else {
                return
            }
            guard
                !Task.isCancelled,
                operationGeneration == self.operationGeneration,
                prefetchGeneration == self.prefetchGeneration
            else {
                return
            }
            readyForwardPrefetches.append(
                ForwardPrefetch(
                    identifier: utterance.prefetchIdentifier,
                    duration: prefetchedDuration
                )
            )
            duration += prefetchedDuration
        }
    }

    private func loadForwardGroupForPrefetch(
        operationGeneration: UInt64,
        prefetchGeneration: UInt64
    ) async -> BufferedUtteranceGroup? {
        guard let iterator = publicationIterator else { return nil }
        var contentToPreserve: ContentElement?
        var advanceCount = 0
        do {
            advanceCount = trailingForwardAdvanceCount
            trailingForwardAdvanceCount = 0
            while true {
                guard publicationIterator === iterator else {
                    return nil
                }
                guard let content = try await iterator.next() else {
                    if publicationIterator === iterator {
                        trailingForwardAdvanceCount = advanceCount
                    }
                    return nil
                }
                advanceCount += 1
                guard publicationIterator === iterator else {
                    return nil
                }
                contentToPreserve = content
                let nextUtterances = try tokenize(content)
                    .flatMap { utterances(for: $0) }
                if !nextUtterances.isEmpty {
                    let group = BufferedUtteranceGroup(
                        content: content,
                        utterances: nextUtterances,
                        iteratorAdvanceCount: advanceCount
                    )
                    forwardGroups.append(group)
                    return group
                }
                guard
                    publicationIterator === iterator,
                    prefetchGeneration == self.prefetchGeneration
                else {
                    trailingForwardAdvanceCount = advanceCount
                    return nil
                }
            }
        } catch {
            if !(error is CancellationError) {
                log(.error, error)
            }
            if let content = contentToPreserve, publicationIterator === iterator {
                forwardGroups.append(
                    BufferedUtteranceGroup(
                        content: content,
                        utterances: nil,
                        iteratorAdvanceCount: advanceCount
                    )
                )
            } else if publicationIterator === iterator {
                trailingForwardAdvanceCount = advanceCount
            }
            return nil
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
        readyForwardPrefetches = []
        preparedStartLocator = nil
        preparedUtterance = nil
        let task = forwardPrefetchTask
        forwardPrefetchTask = nil
        task?.cancel()
        guard
            task != nil ||
            engineStorage is TTSPrefetchingEngine ||
            prefetchCancellationTask != nil
        else {
            return nil
        }
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

    private func rollbackForwardBuffer(generation: UInt64) async {
        guard isCurrentOperation(generation) else { return }
        let advanceCount = forwardGroups.reduce(trailingForwardAdvanceCount) {
            $0 + $1.iteratorAdvanceCount
        }
        forwardGroups = []
        trailingForwardAdvanceCount = 0
        guard let iterator = publicationIterator else { return }

        func preserveRemainingAdvances(_ remaining: Int) {
            guard publicationIterator === iterator else { return }
            trailingForwardAdvanceCount = remaining
            requiresForwardBufferRollback = remaining > 0
        }

        var completed = 0
        do {
            for _ in 0 ..< advanceCount {
                guard isCurrentOperation(generation, iterator: iterator) else {
                    preserveRemainingAdvances(advanceCount - completed)
                    return
                }
                guard try await iterator.previous() != nil else {
                    preserveRemainingAdvances(advanceCount - completed)
                    return
                }
                completed += 1
                guard isCurrentOperation(generation, iterator: iterator) else {
                    preserveRemainingAdvances(advanceCount - completed)
                    return
                }
            }
            requiresForwardBufferRollback = false
        } catch is CancellationError {
            preserveRemainingAdvances(advanceCount - completed)
            return
        } catch {
            preserveRemainingAdvances(advanceCount - completed)
            log(.error, error)
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
