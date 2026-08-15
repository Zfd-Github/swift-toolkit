# TTS Operation and Iterator Ledger Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every TTS playback, forward-prefetch, iterator-recovery, and tokenizer-commit transition explicit and single-owned so cancellation/config races cannot lose prepared content or corrupt iterator accounting.

**Architecture:** Keep the change private to `PublicationSpeechSynthesizer`. Replace scattered task/generation/buffer fields with explicit playback and forward-prefetch operations plus an iterator ledger. Initial `prefetch(from:)` is a preparation phase of the playback operation, not an unowned fourth task. Route every tokenizer result through an immutable operation token and a single commit method that validates ownership before changing queue or ledger state.

**Tech Stack:** Swift concurrency, XCTest, Readium Navigator, existing gated content iterators and test TTS engines.

## Global Constraints

- Do not change `PublicationSpeechSynthesizer` public API, TTS protocol APIs, engine prefetch limits, or user-visible playback semantics.
- Modify only `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift` and `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift`.
- All iterator movement that returns an element records it in `IteratorLedger` before checking a generation.
- `.fetched` retains both raw and prepared content as required by the design. Every recoverable buffered/pending entry retains prepared content and never replaces it with raw content; raw is retained only with a movement ID for token validation.
- All four tokenizer destinations call `commitTokenization`; no caller writes playback utterances or buffered-group utterances after tokenization.
- Preserve weak-self scopes across engine speech/prefetch, iterator movement, cancellation drain, and waiter suspension.
- Use controllable gates, not sleeps, for all race assertions.
- Run `scripts/test.sh ReadiumNavigatorTests` for the affected suite and `scripts/test.sh` before handoff.
- Commit only to `hometail/readium-3.11`; never create or push a `codex/*` branch.

---

## File Structure

- `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift`: private operation/ledger types, operation replacement helpers, ledger transitions, unified token commit, and conversion of playback/prefetch workers.
- `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift`: deterministic regressions proving prepared-content persistence, ledger undo, buffer-slot validity, waiter release, and no lifetime regression.

### Task 1: Establish red tests for prepared-content and destination ownership

**Files:**
- Modify: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift:1472-1813`
- Test: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift`

**Interfaces:**
- Consumes: existing `makeSynthesizer`, `GatedArrayContentIterator`, `PrefetchingTTSEngine`, and `waitUntil`.
- Produces: behavior tests which fail while a recovery path retains raw instead of prepared content or commits to a shifted group.

- [ ] **Step 1: Write the failing prepared-content supersession test**

Start from a locator with `before: "prefix "` and highlight `"kept body"`, then have the first tokenizer invocation re-enter with `next()`. This supersedes the playback generation while retaining the same iterator/ledger entry. Capture every tokenizer input. Assert the next operation's tokenizer invocation and speech are `"kept body"`; neither may contain `"prefix"`. This must not stop and recreate an iterator.

```swift
func testNavigationSupersededTokenizationRetainsPreparedStartText() async throws {
    // Call next() inside the first tokenizer invocation on the same iterator.
    // Assert the successor tokenizes "kept body", never the original prefix.
}
```

- [ ] **Step 2: Verify the test is red**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testNavigationSupersededTokenizationRetainsPreparedStartText`

Expected: FAIL because a superseded recovery path still retains raw content or the behavior cannot be represented.

- [ ] **Step 3: Write the failing retry-exhaustion test**

Use a tokenizer that alternates `config.defaultLanguage` on every call for the trimmed first block until the bounded retry count is exceeded, then stabilizes under French. Trigger a same-iterator navigation/continuation that reuses the retained ledger entry. Record every tokenizer input and assert the first post-exhaustion input and spoken output stay `"kept body"`, not `"prefix kept body"`.

```swift
func testConfigRetryExhaustionRetainsPreparedStartText() async throws {
    // Exhaust retry on one ledger entry, then continue that iterator entry under French.
}
```

- [ ] **Step 4: Strengthen the existing stable-slot characterization and run the red tests**

Extend `testBufferedGroupRetokenizeReentryStopDoesNotCrash` so its synchronous `stop()` reentry also asserts that no stale buffered utterance is prefetched or spoken after the stale tokenizer result returns. This is a green characterization: the current implementation already rejects this stale commit, so it must pass rather than be forced into an invalid timeout. Keep the red cycle focused on the two raw/prepared persistence regressions above.

```swift
func testBufferedGroupRetokenizeReentryStopDoesNotCommitStaleResult() async throws {
    // Return a stale result after synchronous stop and assert it remains unobservable.
}
```

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests`

Expected: the two prepared-content tests fail for `prefix kept body`; the strengthened existing stable-slot characterization passes.

- [ ] **Step 5: Commit the red tests**

```bash
git add Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift
git commit -m "test(navigator): expose TTS tokenization ownership races"
```

### Task 2: Add explicit playback and forward-prefetch operation ownership

**Files:**
- Modify: `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift:190-590, 1224-1799`
- Modify: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift:2214-2559`
- Test: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift`

**Interfaces:**
- Consumes: `DetachedTaskLifecycleHandle`, existing `ForwardPrefetch`, preparation cache behavior, and existing cancellation tests.
- Produces: `PlaybackOperation` with a preparation/playing phase and `ForwardPrefetchOperation` with active/retired drain ownership. The existing iterator fields remain intact until Task 3's atomic ledger migration.

- [ ] **Step 1: Write a failing operation-replacement lifecycle test**

Add per-call prefetch gates/identifiers and a `completesSpeechOnCancellation` option to the test engine, defaulting to existing behavior. Gate old speech and old forward prefetch, invoke pause/resume, then complete the old calls late. Assert only the resumed operation can advance playback and only its prefetch identifier is reused.

```swift
func testReplacingPlaybackOperationLeavesOnlyNewestWorkerPlayable() async throws {
    // Replace a gated worker and prove releasing the old worker cannot speak.
}
```

- [ ] **Step 2: Verify the test is red**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testReplacingPlaybackOperationLeavesOnlyNewestWorkerPlayable`

Expected: FAIL until replacement has one task/lifecycle source of truth.

- [ ] **Step 3: Implement operation types, including initial preparation**

Define this state beside the state-machine comment:

```swift
private enum PlaybackPhase {
    case preparing(startLocator: Locator?)
    case playing
}

private struct PlaybackOperation {
    let generation: UInt64
    let phase: PlaybackPhase
    let task: Task<Void, Never>?
    let lifecycle: DetachedTaskLifecycleHandle
}
```

Make `prefetch(from:)` create a `.preparing` playback operation before it awaits old work, moves the iterator, tokenizes, or engine-prefetches. Its cancellation handler and every prepared-result write validate that exact generation/phase. Make `start(from:)` consume the prepared cache only from its matching preparation operation. Do not move iterator or buffer fields in this task.

Use this forward operation ownership shape; a retired operation remains reachable only until its owned drain completes:

```swift
private struct ForwardPrefetchOperation {
    let generation: UInt64
    let taskID: UInt64
    let task: Task<Void, Never>
    var ready: [ForwardPrefetch]
    let waiters: ContinuationRegistry
    var cancellationTask: Task<Void, Never>?
}
```

- [ ] **Step 4: Implement operation replacement helpers**

Replace `setCurrentTask(_:) ` and dispersed forward task fields with helpers that construct/store operations. A lifecycle handle may remain independently stored for deinitialization, but no second active task identity may be stored outside its operation. A forward operation owns task ID, ready queue, its tagged waiter registry, and cancellation drain. Invalidation detaches the active operation, resumes that detached operation's waiters, cancels task/engine, retains it in a retired-drain collection until its drain completes, and passes the predecessor drain to a successor so engine work remains serialized.

- [ ] **Step 5: Verify behavior and commit**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testReplacingPlaybackOperationLeavesOnlyNewestWorkerPlayable`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testStopDuringForwardPrefetchWaitDoesNotDeadlock`

Expected: PASS.

```bash
git add Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift
git commit -m "refactor(navigator): own TTS playback and prefetch operations"
```

### Task 3: Centralize iterator movement and recovery in the ledger

**Files:**
- Modify: `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift:825-1222, 1394-1620, 1801-1867`
- Test: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift:639-1038, 1706-1753`

**Interfaces:**
- Consumes: existing iterator, pending tuple, forward groups, advance counters, rollback flag, and `Direction`.
- Produces: `IteratorLedger`, `IteratorState`, movement IDs, and methods to record a fetch, create/lease a stable buffer placeholder, begin/complete opposite undo, merge an empty group, and roll back unconsumed advances.

- [ ] **Step 1: Write a failing superseded-fetch undo test**

Extend the gated-iterator setup so a cancelled `next()` returns second, configuration/navigation supersedes that request before it commits, an opposite move is gated, then forward resumes. Assert second appears once, third is neither skipped nor spoken early, and the iterator has at most one concurrent call.

```swift
func testSupersededFetchIsRecordedBeforeOppositeUndo() async throws {
    // Gated next returns second after cancellation; undo and replay must land on second.
}
```

- [ ] **Step 2: Verify the test is red**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testSupersededFetchIsRecordedBeforeOppositeUndo`

Expected: FAIL while fetch accounting is not committed before stale-operation exit.

- [ ] **Step 3: Add the ledger transition methods**

Atomically replace the iterator, pending tuple, forward groups, trailing counter, and rollback flag with one ledger. Assign a UUID movement ID for each non-nil movement before a generation check:

```swift
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

private mutating func recordFetched(
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
```

Use `.undoing` around opposite movement; use `.rollbackRequired` when a rollback suspension is interrupted. Add this explicit transition table to the implementation comment and tests: fetched → undoing before an opposite await; a non-nil opposite result completes/clears undo before generation validation; rollbackRequired(n) decrements immediately after each non-nil reverse movement before generation validation; a tokenizer empty result transfers exactly one placeholder advance to the next placeholder/trailing count; token error/supersession/retry exhaustion leaves the same prepared placeholder recoverable. The ledger alone creates, leases, fills, restores, and merges groups.

- [ ] **Step 4: Convert live and forward iterator workers**

In `loadNextUtterancesFromIterator` and `loadNextForwardGroup`, compute prepared content exactly once immediately after a returned element, call `recordFetched`, then create a ledger-owned placeholder with a stable group ID before tokenization. A forward-group consumer leases (rather than removes) its placeholder before tokenization; throw/cancel/supersession returns that same placeholder to pending state. In `rollbackForwardBuffer`, take work from the ledger and persist unfinished count via `.rollbackRequired(count:)`.

- [ ] **Step 5: Verify and commit**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testSupersededFetchIsRecordedBeforeOppositeUndo`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testPendingOppositeUndoAccountsForCancelThatStillReturnsElement`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testCancellingAfterEmptyRetokenizedGroupRewindsAllBufferedContent`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testPreviousCancelsSuspendedPrefetchAndRollsBackEmptyElement`

Expected: PASS; second is not skipped/duplicated and empty group accounting is recoverable.

```bash
git add Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift
git commit -m "refactor(navigator): centralize TTS iterator recovery"
```

### Task 4: Make tokenizer commit the only mutation path

**Files:**
- Modify: `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift:918-1022, 1025-1222, 1394-1710, 1869-1900`
- Test: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift:1377-1813`

**Interfaces:**
- Consumes: `OperationToken`, `TokenizationDestination`, `TokenCommitResult`, `IteratorLedger`, playback and prefetch operation generations.
- Produces: `TokenizationSource` and `commitTokenization(_:source:token:)` called from four tokenizer destinations.

- [ ] **Step 1: Write a failing forward-candidate reentry test**

Refactor the existing `testBufferedGroupRetokenizeReentryConfigDoesNotCommitStaleResult` tokenizer hook to trigger German only when content `"third"` is tokenized while `"fr second"` is playing, rather than by tokenizer-call count. Assert no French third result queues or speaks and final live playback is `first`, `fr second`, `de third`.

```swift
func testForwardCandidateCommitRejectsConfigSupersededToken() async throws {
    // Flip config when the stable third candidate slot is tokenized.
}
```

- [ ] **Step 2: Verify the test is red**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testForwardCandidateCommitRejectsConfigSupersededToken`

Expected: FAIL until candidate collection shares the same validation as every other destination.

- [ ] **Step 3: Implement the unified commit**

Add a source enum for diagnostics and implement this only MainActor mutation point:

```swift
private func commitTokenization(
    _ utterances: [Utterance],
    source: TokenizationSource,
    token: OperationToken
) -> TokenCommitResult {
    // Stale playback/iterator/destination/movement ID -> .superseded.
    // Live playback config retry with same operation/ledger entry -> .retryWithNewConfig.
    // A changed forward-operation epoch always supersedes its old worker.
    // Matching token -> write token destination and return .committed(utterances).
}
```

Validate playback generation, forward-operation generation, iterator identity, stable destination ID, movement ID, and the ledger raw/prepared payload. Do not identify an entry by content equality: adjacent elements can be equal. The method itself fills the leased placeholder or playback queue. It never changes content to raw.

- [ ] **Step 4: Convert every tokenizer caller**

Convert `consumeForwardGroup`, `loadNextUtterancesFromIterator`, `loadNextForwardGroup`, and `collectForwardPrefetchCandidates` to create a token from a ledger-held playback entry or leased placeholder, tokenize only `token.prepared`, flatten to utterances, and call the commit. Only a still-current live playback operation retries `.retryWithNewConfig`; a forward operation whose epoch changed returns `.superseded` and its successor restarts from the preserved placeholder. Route thrown error, retry exhaustion, cancellation, and `.superseded` through the same lease recovery; remove caller-owned post-tokenize assignments.

- [ ] **Step 5: Verify and commit**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testNavigationSupersededTokenizationRetainsPreparedStartText`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testConfigRetryExhaustionRetainsPreparedStartText`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testForwardCandidateCommitRejectsConfigSupersededToken`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testBufferedGroupRetokenizeReentryConfigDoesNotCommitStaleResult`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testTokenizeReentryDoesNotCommitStaleForwardUtterances`

Expected: PASS.

```bash
git add Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift
git commit -m "refactor(navigator): unify TTS tokenization commits"
```

### Task 5: Complete forward-prefetch operation ownership and verification

**Files:**
- Modify: `Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift:111-1799`
- Modify: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift:13-402, 1039-1900, 2214-2559`

**Interfaces:**
- Consumes: `ForwardPrefetchOperation`, unified token commit, continuation registry.
- Produces: a forward worker whose task ID, ready queue, cancellation drain, and generation-tagged waiters have one owning operation, including a retained predecessor drain while a successor starts.

- [ ] **Step 1: Write a failing drain/waiter test**

Add two deterministic phases. First, use a deferred prefetch engine to prove config invalidation wakes a playback forward-ready waiter. Second, use a tagged multi-call prefetch gate (not the existing one-continuation helper) to hold an old prefetch result until after config then `next()`; assert its stale identifier is never reused and the next live utterance speaks once. Do not claim an iterator load and forward-ready waiter are simultaneously suspended in the serial worker.

```swift
func testInvalidatingForwardOperationDrainsAndRejectsStaleReadyResult() async throws {
    // Independently prove waiter wakeup and late old-result rejection.
}
```

- [ ] **Step 2: Verify the test is red**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testInvalidatingForwardOperationDrainsAndRejectsStaleReadyResult`

Expected: FAIL until task, ready queue, drain, and waiter ownership are atomic.

- [ ] **Step 3: Convert prefetch start, finish, wait, and invalidate**

Make `startForwardPrefetch`, `finishForwardPrefetch`, `waitUntilNextForwardReadyOrFinished`, and `invalidatePrefetch` look up an operation by generation/task ID. Append accepted engine results only to its ready queue. Invalidation immediately resumes the detached operation's tagged waiters, then retains that operation until its drain completes; deinit resumes waiters from active and retired operations. The successor awaits the detached predecessor drain before engine work. Finish/ready writes validate generation and task ID while retaining weak-self scopes.

- [ ] **Step 4: Delete obsolete primary state and update invariants**

Migrate every entry point: `config.didSet`, `deinit`, `prefetch(from:)`, `start`, `stop`, `pause`, `resume`, `next`, `previous`, prepared-prefetch cache consumption, ready-prefetch consumption, and waiter registration. Then delete legacy task fields, independent task ID/ready/cancellation fields, pending tuple, trailing counter, rollback flag, and their ad hoc helper mutations. Rewrite the state-machine comment to name the operation, preparation phase, ledger, and unified-commit invariants.

- [ ] **Step 5: Run all verification and commit**

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testReleasingSynthesizerDuringForwardEnginePrefetchCancelsWork`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testReleasingSynthesizerDuringForwardPrefetchWaitAllowsDeinit`

Run: `scripts/test.sh ReadiumNavigatorTests/PublicationSpeechSynthesizerTests/testReleasingSynthesizerAfterEmptyContentWhileIteratorIsSuspended`

Run: `scripts/test.sh ReadiumNavigatorTests`

Run: `scripts/test.sh`

Run: `git diff --check`

Expected: all tests pass and no whitespace errors. Record any unrelated pre-existing failure without suppressing it.

```bash
git add Sources/Navigator/TTS/PublicationSpeechSynthesizer.swift Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift
git commit -m "refactor(navigator): own TTS forward prefetch operation"
```
