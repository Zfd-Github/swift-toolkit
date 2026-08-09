# TTS Operation and Iterator Ledger Design

## Goal

Replace the synthesizer's distributed playback, forward-prefetch, iterator-accounting, and tokenizer-commit state with explicit private operations and a single iterator ledger, without changing the public `PublicationSpeechSynthesizer` API or observable playback behavior.

## Scope

The change is confined to `PublicationSpeechSynthesizer` and its existing Navigator tests. It removes the private `currentTask`, `forwardPrefetchTask`, pending iterator tuple, independent rollback flag, and duplicate generation/accounting fields as primary state. Public API, TTS engine protocols, configuration semantics, and prefetch waterline behavior remain unchanged.

## Architecture

`PublicationSpeechSynthesizer` owns three private nested state types:

```swift
private struct PlaybackOperation {
    let generation: UInt64
    let task: Task<Void, Never>
    let lifecycle: DetachedTaskLifecycleHandle
}

private struct ForwardPrefetchOperation {
    let generation: UInt64
    let taskID: UInt64
    let task: Task<Void, Never>
    var ready: [ForwardPrefetch]
    var cancellationTask: Task<Void, Never>?
}

private struct IteratorLedger {
    let iterator: ContentIterator
    var state: IteratorState
    var forwardGroups: [BufferedUtteranceGroup]
    var trailingAdvanceCount: Int
}
```

The lifecycle handles remain independently owned so `deinit` can cancel suspended tasks without a MainActor hop. A replaced operation is cancelled before its lifecycle ownership is cleared. `prefetch(from:)` is a preparation phase of `PlaybackOperation`, so its task, cancellation, iterator movement, and prepared result have the same owner as playback rather than a separate request-generation field. `PlaybackOperation` and `ForwardPrefetchOperation` are the sole source of truth for their task identities and queues.

## Iterator Ledger

`IteratorLedger` represents the cursor and all unconsumed movement:

```swift
private enum IteratorState {
    case synchronized
    case fetched(direction: Direction, raw: ContentElement, prepared: ContentElement)
    case undoing(originalDirection: Direction, prepared: ContentElement)
    case rollbackRequired(count: Int)
}
```

Only the ledger may record a content element after an iterator movement. Each record receives a movement ID. Any successful `next` or `previous` result is recorded before checking whether its initiating operation is still current. This makes a cancellation that still returns content recoverable by type, rather than relying on an optional tuple.

Buffered forward groups and trailing advances remain ledger properties. A buffered group carries a stable group ID, movement ID, raw content, and prepared content; invalidation, cancellation, retry exhaustion, and recovery preserve its prepared content. A freshly moved forward element becomes a ledger-owned placeholder before tokenization, and a consumer leases that placeholder rather than removing it. Empty groups merge their advance count into the next group or trailing count through ledger methods; no caller directly combines counts or toggles a rollback Boolean.

## Operation Tokens and Unified Tokenization Commit

Each tokenizer call begins with an immutable token:

```swift
private struct OperationToken {
    let playbackGeneration: UInt64
    let prefetchGeneration: UInt64
    let iterator: ContentIterator
    let movementID: UUID
    let destination: TokenizationDestination
    let raw: ContentElement
    let prepared: ContentElement
}

private enum TokenizationDestination {
    case playback
    case forwardGroup(id: UUID)
    case forwardCandidate(id: UUID)
}

private enum TokenCommitResult {
    case committed([Utterance])
    case retryWithNewConfig
    case superseded
}
```

The exact destination representation uses a stable buffered-group identifier rather than a mutable array index. Along with the movement ID, it identifies one leased buffer slot across tokenizer re-entry and cannot permit a result to be written to a different group after an array mutation.

All tokenization paths (`consumeForwardGroup`, playback iterator loading, forward group loading, and forward candidate collection) prepare content once, call the tokenizer, and delegate every state write to:

```swift
private func commitTokenization(
    _ utterances: [Utterance],
    source: TokenizationSource,
    token: OperationToken
) -> TokenCommitResult
```

`commitTokenization` validates the playback generation, prefetch/config generation, iterator identity, destination identity, and raw/prepared ledger identity. It is the only code permitted to write playback utterances, buffered-group utterances, or tokenization-related pending ledger state.

When configuration changes during a still-current live playback operation, it returns `.retryWithNewConfig`; the caller retries with the token's existing `prepared` content. A configuration change that invalidates a forward operation supersedes its worker; its successor restarts from the preserved placeholder. When playback, iterator, movement, or destination no longer matches, it returns `.superseded` without committing stale output. Supersession, tokenizer failure, cancellation, and retry exhaustion use ledger transitions to preserve the prepared content needed for later recovery. No path may replace it with raw content.

## Lifecycle Rules

`start`, `resume`, `next`, `previous`, `pause`, and `stop` create, replace, or cancel `PlaybackOperation` through dedicated helpers. Configuration changes and navigation invalidate a complete `ForwardPrefetchOperation`: its task, ready queue, cancellation drain, and waiters move together.

Each forward operation owns generation-tagged waiters alongside its ready queue. Invalidating prefetch detaches the old operation, resumes its waiters immediately, and retains it until its owned cancellation drain completes; a successor awaits that drain before engine work. `deinit` resumes waiters from active and retired operations. Worker tasks retain the synthesizer weakly across `speak`, iterator movement, prefetching, cancellation drains, and waiter suspension.

## Error Handling

Iterator errors, tokenizer errors, cancelled tasks, stale generations, retry exhaustion, and prefetch failure leave state in an explicit ledger state that can be consumed, undone, or rolled back. They never commit stale tokens, skip a moved element, or discard a prepared locator trim. The existing bounded configuration retry limit remains in force.

## Tests

Existing speech, navigation, prefetch, memory-release, and retry tests remain green. Tests will use controllable iterator/tokenizer/engine gates rather than timing where a race is under test. Required regressions include:

- Config changes during every tokenizer destination preserve the same prepared (trimmed) content through retry, generation failure, and retry exhaustion.
- `stop`, `next`, or `previous` from tokenizer re-entry cannot commit into a cleared or shifted buffer slot.
- A cancelled iterator operation that still returns an element records ledger state before supersession, and opposite-direction undo yields each element exactly once.
- Empty buffered groups transfer their iterator advance count without retaining the synthesizer through a subsequently gated iterator call.
- Prefetch invalidation cancels and drains the operation coherently, wakes waiters, and prevents stale ready results from becoming playable.

## Non-Goals

This change does not alter public APIs, introduce a new actor, change tokenizer output semantics, modify engine prefetch duration policy, or split the synthesizer into new source files.
