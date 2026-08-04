//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared

protocol AVSpeechOutput: AnyObject {
    func speak(_ utterance: AVSpeechUtterance)
    func stop()
}

public protocol AVTTSEngineDelegate: AnyObject {
    /// Called when the engine created a new utterance to be played.
    /// You can customize additional properties of the utterance.
    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance)
}

/// Implementation of a `TTSEngine` using Apple AVFoundation's `AVSpeechSynthesizer`.
public class AVTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate, Loggable {
    /// Range of valid values for an AVUtterance rate.
    ///
    /// > The speech rate is a decimal representation within the range of `AVSpeechUtteranceMinimumSpeechRate` and
    /// > `AVSpeechUtteranceMaximumSpeechRate`. Lower values correspond to slower speech, and higher values correspond to
    /// > faster speech. The default value is `AVSpeechUtteranceDefaultSpeechRate`.
    /// > https://developer.apple.com/documentation/avfaudio/avspeechutterance/1619708-rate
    private static let avRateRange =
        Double(AVSpeechUtteranceMinimumSpeechRate) ... Double(AVSpeechUtteranceMaximumSpeechRate)

    /// Range of valid values for an AVUtterance pitch.
    ///
    /// > Before enqueuing the utterance, set this property to a value within the range of 0.5 for lower pitch to 2.0 for
    /// > higher pitch. The default value is 1.0.
    /// > https://developer.apple.com/documentation/avfaudio/avspeechutterance/1619683-pitchmultiplier
    private static let avPitchRange = 0.5 ... 2.0

    public weak var delegate: AVTTSEngineDelegate?

    private let debug: Bool = false
    private let synthesizer = AVSpeechSynthesizer()
    private let speechOutput: any AVSpeechOutput
    private let resolveVoiceIdentifier: (String) -> AVSpeechSynthesisVoice?
    private let resolveVoiceLanguage: (Language) -> AVSpeechSynthesisVoice?

    /// Creates a new `AVTTSEngine` instance.
    public init(
        delegate: AVTTSEngineDelegate? = nil
    ) {
        self.delegate = delegate
        speechOutput = SystemAVSpeechOutput(synthesizer: synthesizer)
        resolveVoiceIdentifier = { AVSpeechSynthesisVoice(identifier: $0) }
        resolveVoiceLanguage = { AVSpeechSynthesisVoice(language: $0) }

        super.init()
        synthesizer.delegate = self
    }

    init(
        delegate: AVTTSEngineDelegate? = nil,
        speechOutput: any AVSpeechOutput,
        resolveVoiceIdentifier: @escaping (String) -> AVSpeechSynthesisVoice?,
        resolveVoiceLanguage: @escaping (Language) -> AVSpeechSynthesisVoice?
    ) {
        self.delegate = delegate
        self.speechOutput = speechOutput
        self.resolveVoiceIdentifier = resolveVoiceIdentifier
        self.resolveVoiceLanguage = resolveVoiceLanguage
        super.init()
    }

    public lazy var availableVoices: [TTSVoice] =
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                // Remove novelty, eloquence and "classic" voices, as they are
                // not a good modern fit to read publications.
                if
                    #available(iOS 17.0, *),
                    voice.voiceTraits.contains(.isNoveltyVoice) ||
                    voice.voiceTraits.contains(.isPersonalVoice)
                {
                    return false
                }

                return !voice.identifier.contains(".eloquence.")
                    && !voice.identifier.starts(with: "com.apple.speech.synthesis.voice.")
            }
            .map { TTSVoice(voice: $0) }

    public func voiceWithIdentifier(_ id: String) -> TTSVoice? {
        resolveVoiceIdentifier(id)
            .map { TTSVoice(voice: $0) }
    }

    @MainActor
    public func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        let task = Task(
            utterance: utterance,
            onSpeakRange: onSpeakRange
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                task.continuation = $0
                on(.play(task))
            }
        } onCancel: {
            task.cancel()
            Swift.Task { @MainActor [weak self] in
                self?.on(.stop(task))
            }
        }
    }

    @MainActor
    public func switchVoice(to identifier: String?) -> Bool {
        let task: Task
        switch state {
        case let .starting(current), let .playing(current):
            task = current
        case let .stopping(current, _) where current.shouldRestart:
            task = current
        case .stopped, .stopping:
            return false
        }

        let voiceSelection: VoiceSelection
        if let identifier {
            guard let voice = resolveVoiceIdentifier(identifier) else {
                return false
            }
            voiceSelection = .explicit(voice)
        } else {
            voiceSelection = .system
        }

        let startIndex = task.lastRange?.lowerBound ?? task.utterance.text.startIndex
        guard startIndex < task.utterance.text.endIndex else {
            return false
        }
        task.voiceSelection = voiceSelection
        task.startIndex = startIndex
        task.shouldRestart = true
        on(.restart(task))
        return true
    }

    private class Task: @unchecked Sendable, Equatable, CustomStringConvertible {
        let utterance: TTSUtterance
        private let onSpeakRange: (Range<String.Index>) -> Void
        private let cancellationLock = NSLock()
        var continuation: CheckedContinuation<Result<Void, TTSError>, Never>!
        private var cancellationRequested = false
        var startIndex: String.Index
        var lastRange: Range<String.Index>?
        var voiceSelection: VoiceSelection = .utterance
        var shouldRestart = false
        var hasEnqueuedUtterance = false

        init(utterance: TTSUtterance, onSpeakRange: @escaping (Range<String.Index>) -> Void) {
            self.utterance = utterance
            self.onSpeakRange = onSpeakRange
            startIndex = utterance.text.startIndex
        }

        var description: String {
            utterance.text
        }

        static func == (lhs: Task, rhs: Task) -> Bool {
            ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
        }

        func onSpeakRange(_ range: Range<String.Index>) {
            guard !isCancelled else {
                return
            }
            lastRange = range
            onSpeakRange(range)
        }

        func finish() {
            continuation?.resume(returning: .success(()))
            continuation = nil
        }

        func cancel() {
            cancellationLock.lock()
            cancellationRequested = true
            cancellationLock.unlock()
        }

        var isCancelled: Bool {
            cancellationLock.lock()
            defer { cancellationLock.unlock() }
            return cancellationRequested
        }
    }

    private func taskUtterance(with task: Task) -> TaskUtterance {
        let utter = TaskUtterance(task: task)
//        utter.rate = rateMultiplierToAVRate(task.utterance.rateMultiplier)
//        utter.pitchMultiplier = Float(task.utterance.pitchMultiplier)
        utter.preUtteranceDelay = task.hasEnqueuedUtterance ? 0 : task.utterance.delay
        task.hasEnqueuedUtterance = true
        utter.voice = voice(for: task)
        delegate?.avTTSEngine(self, didCreateUtterance: utter)
        return utter
    }

    private class TaskUtterance: AVSpeechUtterance {
        let task: Task
        let startIndex: String.Index

        init(task: Task) {
            self.task = task
            startIndex = task.startIndex
            super.init(string: String(task.utterance.text[startIndex...]))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else {
            return
        }
        on(.didStart(task))
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else {
            return
        }
        on(.didFinish(task))
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let task = (utterance as? TaskUtterance)?.task else {
            return
        }
        on(.didFinish(task))
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance avUtterance: AVSpeechUtterance) {
        guard
            let utterance = avUtterance as? TaskUtterance,
            let range = Range(characterRange, in: utterance.speechString)
        else {
            return
        }
        let task = utterance.task
        guard let startIndex = utterance.startIndex.samePosition(in: task.utterance.text.utf16) else {
            return
        }
        let offset = task.utterance.text.utf16.distance(
            from: task.utterance.text.utf16.startIndex,
            to: startIndex
        )
        let lower = offset + utterance.speechString.utf16.distance(
            from: utterance.speechString.utf16.startIndex,
            to: range.lowerBound
        )
        let upper = offset + utterance.speechString.utf16.distance(
            from: utterance.speechString.utf16.startIndex,
            to: range.upperBound
        )
        guard
            lower >= 0,
            lower <= upper,
            upper <= task.utterance.text.utf16.count
        else {
            return
        }
        on(.willSpeakRange(
            String.Index(utf16Offset: lower, in: task.utterance.text)
                ..< String.Index(utf16Offset: upper, in: task.utterance.text),
            task: task
        ))
    }

    // MARK: State machine

    // Submitting new utterances to `AVSpeechSynthesizer` when the `didStart` or
    // `didFinish` events for the previous utterance were not received triggers
    // a deadlock on iOS 15. The engine ignores the following requests.
    //
    // The following state machine is used to make sure we never send commands
    // to the `AVSpeechSynthesizer` when it's not ready.
    //
    // To visualize it, paste the following dot graph in https://edotor.net
    /*
        digraph {
            {
                stopped [style=filled]
            }

            stopped -> starting [label = "play"]

            starting -> playing [label = "didStart"]
            starting -> stopping [label = "play/stop"]

            playing -> stopped [label = "didFinish"]
            playing -> stopping [label = "play/stop"]
            playing -> playing [label = "willSpeakRange"]

            stopping -> stopping [label = "play/stop"]
            stopping -> stopping [label = "didStart"]
            stopping -> starting [label = "didFinish w/ next"]
            stopping -> stopped [label = "didFinish w/o next"]
        }
     */

    /// Represents a state of the TTS engine.
    private enum State: Equatable {
        /// The TTS engine is waiting for the next utterance to play.
        case stopped
        /// A new utterance is being processed by the TTS engine, we wait for didStart.
        case starting(Task)
        /// The utterance is currently playing and the engine is ready to process other commands.
        case playing(Task)
        /// The engine was stopped while processing the previous utterance, we wait for didStart
        /// and/or didFinish. The queued utterance will be played once the engine is successfully stopped.
        case stopping(Task, queued: Task?)
    }

    /// State machine events triggered by the `AVSpeechSynthesizer` or the client
    /// of `AVTTSEngine`.
    private enum Event: Equatable {
        // AVTTSEngine commands
        case play(Task)
        case stop(Task)
        case restart(Task)

        // AVSpeechSynthesizer delegate events
        case didStart(Task)
        case willSpeakRange(Range<String.Index>, task: Task)
        case didFinish(Task)
    }

    private var state: State = .stopped {
        didSet {
            if debug {
                log(.debug, "* \(state)")
            }
        }
    }

    /// Raises a TTS event triggering a state change and handles its side effects.
    private func on(_ event: Event) {
        assert(Thread.isMainThread, "Raising AVTTSEngine events must be done from the main thread")

        if debug {
            log(.debug, "-> on \(event)")
        }

        switch (state, event) {
        // stopped
        case let (.stopped, .play(task)):
            state = .starting(task)
            startEngine(with: task)

        // starting

        case let (.starting(current), .didStart(started)) where current == started:
            state = .playing(current)

        case let (.starting(current), .play(next)):
            state = .stopping(current, queued: next)

        case let (.starting(current), .stop(toStop)) where current == toStop:
            state = .stopping(current, queued: nil)

        case let (.starting(current), .restart(task)) where current == task:
            state = .stopping(current, queued: nil)

        // playing

        case let (.playing(current), .didFinish(finished)) where current == finished:
            state = .stopped

            current.finish()

        case let (.playing(current), .play(next)):
            state = .stopping(current, queued: next)
            stopEngine()

        case let (.playing(current), .stop(toStop)) where current == toStop:
            state = .stopping(current, queued: nil)
            stopEngine()

        case let (.playing(current), .restart(task)) where current == task:
            state = .stopping(current, queued: nil)
            stopEngine()

        case let (.playing(current), .willSpeakRange(range, task: speaking)) where current == speaking:
            current.onSpeakRange(range)

        // stopping

        case let (.stopping(current, queued: next), .didStart(started)) where current == started:
            state = .stopping(current, queued: next)
            stopEngine()

        case let (.stopping(current, queued: next), .didFinish(finished)) where current == finished:
            if current.shouldRestart, !current.isCancelled, next == nil {
                current.shouldRestart = false
                state = .starting(current)
                startEngine(with: current)
            } else {
                if let next = next, !next.isCancelled {
                    state = .starting(next)
                    startEngine(with: next)
                } else {
                    next?.finish()
                    state = .stopped
                }
                current.finish()
            }

        case let (.stopping(current, queued: previous), .play(next)):
            previous?.finish()
            current.shouldRestart = false
            state = .stopping(current, queued: next)

        case let (.stopping(current, queued: next), .stop(toStop)) where current == toStop:
            state = .stopping(current, queued: next)

        case let (.stopping(current, queued: next), .stop(toStop)) where next == toStop:
            toStop.finish()
            state = .stopping(current, queued: nil)

        case let (.stopping(_, queued: _), .stop(toStop)):
            toStop.finish()

        case let (.stopped, .stop(task)):
            task.finish()

        default:
            break
        }
    }

    private func startEngine(with task: Task) {
        speechOutput.speak(taskUtterance(with: task))
    }

    private func stopEngine() {
        speechOutput.stop()
    }

    private enum VoiceSelection {
        case utterance
        case system
        case explicit(AVSpeechSynthesisVoice)
    }

    private func voice(for task: Task) -> AVSpeechSynthesisVoice? {
        switch task.voiceSelection {
        case .system:
            return resolveVoiceLanguage(task.utterance.language)
        case let .explicit(voice):
            return voice
        case .utterance:
            break
        }

        switch task.utterance.voiceOrLanguage {
        case let .left(voice):
            return resolveVoiceIdentifier(voice.identifier)
        case let .right(language):
            return resolveVoiceLanguage(language)
        }
    }
}

private final class SystemAVSpeechOutput: AVSpeechOutput {
    private let synthesizer: AVSpeechSynthesizer

    init(synthesizer: AVSpeechSynthesizer) {
        self.synthesizer = synthesizer
    }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private extension TTSVoice {
    init(voice: AVSpeechSynthesisVoice) {
        self.init(
            identifier: voice.identifier,
            language: Language(code: .bcp47(voice.language)),
            name: voice.name,
            gender: Gender(voice: voice),
            quality: Quality(voice: voice)
        )
    }
}

private extension TTSVoice.Gender {
    init(voice: AVSpeechSynthesisVoice) {
        if #available(iOS 13.0, *) {
            switch voice.gender {
            case .unspecified:
                self = .unspecified
            case .male:
                self = .male
            case .female:
                self = .female
            @unknown default:
                self = .unspecified
            }
        } else {
            self = .unspecified
        }
    }
}

private extension TTSVoice.Quality {
    init?(voice: AVSpeechSynthesisVoice) {
        switch voice.quality {
        case .default:
            if voice.identifier.contains(".compact.") {
                self = .low
            } else if voice.identifier.contains(".super-compact.") {
                self = .lower
            } else {
                self = .medium
            }
        case .enhanced:
            self = .high
        #if swift(>=5.7)
            case .premium:
                self = .higher
        #endif
        @unknown default:
            return nil
        }
    }
}

private extension AVSpeechSynthesisVoice {
    convenience init?(language: Language) {
        self.init(language: language.code.bcp47)
    }
}
