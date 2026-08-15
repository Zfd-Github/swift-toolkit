# EPUB Navigation Executor Design

## Goal

Make every EPUB reading-position mutation serial, deadline-bounded, generation-safe, and verifiably complete. A WebKit hang, late callback, process termination, cancellation, or overlapping user command must end in either a verified stable locator or an explicit bounded failure; it must never leave the navigator suspended or allow an old WebView to overwrite newer navigation.

## Scope

The executor owns all operations that can change the reading position:

- forward and backward navigation;
- locator and link jumps;
- page-turn prepare, commit, reverse, and cancellation recovery;
- hard-abort locator restore;
- reload-based restore;
- WebContent termination replacement;
- preference, layout, size, and pagination changes that reload spreads.

Snapshot capture, decoration updates, selection, and viewport observation remain outside the mutation executor unless they initiate one of the operations above. Their callbacks must still be rejected when their pagination or spread generation is stale.

## Architecture

### NavigationOperationExecutor

`NavigationOperationExecutor` is a `@MainActor` serial executor owned by `EPUBNavigatorViewController`. It is the only component allowed to start a position mutation. It owns:

- the monotonically increasing `operationID`;
- the active `NavigationOperationToken`;
- a bounded intent-aware pending queue;
- the Task executing the active operation;
- the terminal-result continuation for every submitted request;
- the poison/replacement recovery phase.

The executor does not release the active lease when the operation body merely returns. It releases it only after one of these terminal conditions:

1. the target location was verified while the token still owned the current pagination and WebView generations;
2. the operation failed without submitting an untrusted WebKit mutation and the navigator is still at its last stable locator;
3. the affected WebView generation was poisoned, detached, replaced, loaded, restored to the last stable locator, and verified;
4. replacement itself reached its deadline, producing a bounded terminal failure and explicit navigator error state.

Recovery is an executor phase, not a separately scheduled operation. Recovery code may not create an independent Task or acquire a second mutation lease.

### Intent-aware queue semantics

- Absolute locator/link jumps are latest-wins. A newer queued absolute target completes the older queued request with `.superseded`.
- Preference/layout reloads are latest-wins and retain only the latest settings snapshot.
- Relative forward/backward commands are ordered and bounded to one pending command behind the active operation. An additional command supersedes that pending command rather than growing an unbounded queue.
- An opposite-direction gesture becomes the single pending relative command. It never runs concurrently with active recovery.
- Hard abort, cancellation, deadline expiry, and WebContent termination affect the active operation and enter its recovery phase. They are not ordinary queue entries.
- Queue waiting time counts against each operation deadline. An expired queued request completes `.timedOut` without touching pagination.

### Operation token and deadline

`NavigationOperationToken` is a reference type passed through every mutation layer. It contains:

- `operationID`;
- an absolute `ContinuousClock.Instant` deadline created when the request is submitted;
- current lifecycle state (`queued`, `running`, `recovering`, or terminal);
- expected pagination generation;
- expected spread identity and WebView generation when a spread is involved;
- cancellation/supersession reason;
- one-shot terminal arbitration.

Every async boundary calls `token.check(...)` immediately before and after awaiting. The check rejects:

- a token no longer owned by the executor;
- a cancelled Task;
- cancellation or supersession;
- an expired deadline;
- a changed pagination generation;
- a changed or poisoned spread/WebView generation.

The deadline begins at submission and covers queue wait, spread loading, page readiness, JavaScript, scroll animation, preview and location calculation, display-frame waits, recovery, WebView replacement, and final stability verification.

### Results

All internal position-mutating APIs return:

```swift
enum NavigationResult {
    case applied
    case cancelled
    case timedOut
    case superseded
    case spreadNotLoaded
    case webContentTerminated
    case failed(any Error)
}
```

Value-producing WebKit calls return `NavigationValueResult<Value>`, which contains a `NavigationResult` plus an optional value. No navigation layer converts failure to success or discards a lower-layer result. Existing public `Bool` APIs map only `.applied` to `true` after executor-owned verification.

### Pagination and WebView generations

`PaginationView` owns a monotonically increasing generation. Reloading or replacing its loaded views increments the generation and resolves all generation-bound waiters.

Each `EPUBSpreadView` owns an immutable spread generation and a mutable WebView generation. A token binds to both before submitting WebKit work. `clear()`, load failure, termination, timeout, or explicit poison resolves all pending waiters and prevents the generation from accepting later callbacks.

Late callbacks capture the operation ID and both generations. They are ignored unless all three still match.

### Poison and replacement

A deadline or WebContent loss after WebKit mutation submission makes that WebView generation untrusted. The executor must:

1. mark the spread generation poisoned;
2. stop loading and resolve every waiter exactly once;
3. detach the affected spread from `PaginationView` so late WebKit side effects are outside the navigation tree;
4. increment the pagination generation;
5. create a new spread/WKWebView generation;
6. load it at the last stable locator;
7. verify href and resource-local position within tolerance;
8. publish only after verification;
9. release the executor lease and start the next non-expired request.

Normal completion reuses the WebView. Only timeout, process termination, or a failure that leaves WebKit side effects uncertain requires replacement.

## Navigation flow

All public and internal mutations use this sequence:

1. Submit an intent and create its token/deadline.
2. Executor applies queue coalescing.
3. When active, bind the token to current pagination generation.
4. Resolve the target and bind the target spread/WebView generation.
5. Execute the mutation while propagating the token.
6. Validate the requested target while ownership is still current.
7. On success, update the stable locator and publish location callbacks.
8. On ordinary pre-submit failure, complete explicitly without publishing.
9. On cancellation after mutation submission, run the single recovery state machine.
10. On timeout or WebContent loss, poison and replace before releasing the lease.

## Target verification

- Cross-spread navigation requires `PaginationView.currentIndex` to equal the target index and the current view to belong to the token's generation.
- Same-spread navigation validates the resulting page index or progression within a fixed tolerance derived from page width/position data.
- Locator jumps require an equivalent href plus progression, position, or fragment agreement.
- Reverse recovery requires the saved original locator.
- Reload recovery requires a new WebView generation and the saved stable locator.

JavaScript callback completion is never sufficient by itself. A failure or an unverified target never invokes `didJumpTo`, `.moved`, `.loaded`, location publication, or preview publication as success.

## Single recovery state machine

The executor owns exactly one recovery chain for the active token:

1. inverse navigation;
2. verified locator restore;
3. WebView generation replacement and verified reload;
4. bounded terminal failure.

Each stage begins only after the previous stage returns an explicit non-success result. Hard abort can replace a recovery request that has not started, but it cannot run a second recovery concurrently. Once WebKit work has started, the stage either completes normally or reaches the shared deadline and poisons the generation.

## Waiter rules

Every continuation-based wait is wrapped in a one-shot waiter registered against the token and relevant generation. It must resolve on:

- successful completion;
- Task cancellation;
- token cancellation or supersession;
- deadline expiry;
- pagination generation change;
- spread clear;
- WebContent termination;
- explicit poison.

No raw `CheckedContinuation` may remain in navigation, pagination readiness, page-turn animation/display-frame, snapshot settle, spread load, script evaluation, or recovery code.

## Migration strategy

The migration remains buildable after each stage:

1. introduce result/token/deadline/waiter types and executor tests without routing production navigation;
2. convert PageView/PaginationView/Spread go and JavaScript paths to tokens and explicit results;
3. route direct and relative navigation through the executor;
4. move page-turn transactions and all recovery into the active executor operation;
5. implement poison/replacement and callback generation rejection;
6. route reload/preferences/termination mutations;
7. remove compatibility Bool/internal Task paths and audit continuations.

The existing public Navigator Bool API remains source-compatible.

## Testing

Tests use real production executor, pagination, spread, and navigator paths with controllable fault boundaries. They cover:

- spread load never completes;
- JavaScript never calls back, fails, times out, and executes late;
- operation A times out immediately before operation B;
- recovery with hard abort;
- recovery concurrent with locator jump;
- WebContent termination during load, script, scroll, and recovery;
- old WebView callbacks after replacement;
- repeated reverse gestures with external cancellation;
- explicit target-verification failure;
- exactly one active mutation, one terminal result, and one waiter resume;
- final idle or explicit error state.

The test script must preserve the real `xcodebuild` exit code. Final verification runs the complete `ReadiumNavigatorTests` suite ten consecutive times on the same simulator, each under an outer watchdog, and checks for remaining xctest processes and executor/waiter/recovery diagnostics after every run.

## Non-goals

- Changing public Navigator APIs from Bool in this release.
- Retrying arbitrary JavaScript that does not mutate reading position.
- Preserving an unbounded history of rapid user commands.
- Reusing a WebView generation after timeout or process termination.
