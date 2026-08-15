# EPUB Navigation Transaction Invariants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every EPUB reading-position mutation deadline-bounded, executor-owned, evidence-preserving, and safe against stale same-spread publication.

**Architecture:** The executor owns terminal lease release even when a cancelled Swift task never cooperates, and invokes a synchronous navigator isolation hook before starting later work. Explicit non-optional operation tokens and `NavigationMutationResult` values flow through page-turn, pagination, recovery, settle, and link-resolution paths. Final publication uses a synchronous viewport revision stamp so a location calculated across an `await` cannot commit after an intervening same-spread move.

**Tech Stack:** Swift 6, UIKit, WebKit, Swift Testing, Xcode test plans.

## Global Constraints

- Keep all Hometail changes on `hometail/readium-3.11`.
- Do not create, use, or push `codex/*` branches.
- Preserve unrelated user changes in the dirty worktree.
- Preserve the public `Navigator` Bool API only at the final public boundary.
- Every production behavior change follows a red-green test cycle.
- Never release a timed-out mutation lease before synchronously poisoning and isolating its live pagination generation.

---

### Task 1: Hard deadline lease retirement

**Files:**
- Modify: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/EPUB/NavigationOperationExecutorTests.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: `NavigationOperationExecutor.init(isolateAbandonedOperation:)` with a mandatory synchronous isolation callback.
- Produces: deadline retirement which completes the request waiter and starts queued work without awaiting a non-cooperative body.
- Produces: navigator isolation which stores the last stable locator, poisons spreads, and calls `PaginationView.isolateForDeferredReload()` before lease release.

- [ ] Add an executor regression whose first body ignores cancellation, then assert its deadline runs isolation and allows a queued request to start before the first body returns.
- [ ] Run the regression and confirm the executor remains active until the blocked body is manually released.
- [ ] Add mandatory active-operation isolation to the executor and make deadline/owner-abort finish the request independently of body completion.
- [ ] Wire the navigator isolation callback and synchronously retire page-turn recovery bookkeeping.
- [ ] Run executor and active-deadline page-turn regressions.

### Task 2: Preserve mutation evidence to the public boundary

**Files:**
- Modify: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/Toolkit/PaginationViewTests.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: `NavigationMutationResult` carrying `result`, `mayHaveMutated`, `stableLocator`, `stableVerified`, and `failureStage`.
- Produces: token-aware `PaginationView.goToIndex` and page-turn/existing-path routing returning `NavigationMutationResult`.
- Consumes: public `go` methods map only the final terminal result to Bool.

- [ ] Add tests proving partial mutation failures preserve `mayHaveMutated`, stage, and stable-location evidence.
- [ ] Run them and confirm current `NavigationResult`/Bool overloads erase the evidence.
- [ ] Enrich `NavigationMutationResult` and propagate it through pagination, page-turn navigation, route selection, relative navigation, verification, and recovery.
- [ ] Remove the token-aware `goToIndex -> NavigationResult` compression overload.
- [ ] Run focused pagination and page-turn tests.

### Task 3: Explicit operation ownership and registered recovery

**Files:**
- Modify: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/EPUB/EPUBSpreadView.swift`
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: non-optional `NavigationOperationToken` parameters for mutation, recovery, verification, and frame-wait paths.
- Removes: mutation-time `NavigationOperationContext` and conditional detached-task registration.

- [ ] Add regressions for operation-aware vertical false verification and recovery registration.
- [ ] Run them and confirm `.applied(false)` and nil-token paths are accepted.
- [ ] Match Bool waiter results only with `case .applied(true)`.
- [ ] Thread the executor token explicitly through page-turn transaction, preview, restore, poisoned replacement, and location publication helpers.
- [ ] Replace detached recovery with registered operation-owned tasks whose token cannot be nil.
- [ ] Remove synthetic/TaskLocal mutation fallbacks from internal navigation APIs.
- [ ] Run focused lifecycle and page-turn regressions.

### Task 4: Executor-owned settle and link resolution

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: `settlePageTurn` submits `settleRecovering` restoration as a reload operation with an explicit token.
- Produces: `go(to: Link)` resolves `publication.locate` and navigates in one absolute executor operation.

- [ ] Add a settle-vs-jump serialization test and a link-location deadline test.
- [ ] Run them and confirm restore/locate currently execute outside executor ownership.
- [ ] Submit settle recovery through the executor and pass its token to restore/release helpers.
- [ ] Move link resolution into the same submit body as locator navigation, racing it with operation cancellation.
- [ ] Run focused tests.

### Task 5: Fail-closed recovery and same-spread commit revision

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/EPUB/EPUBSpreadView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift`
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: monotonic pagination/spread viewport revisions captured in the final target stamp.
- Produces: exact target revalidation and revision comparison immediately before synchronous publication.

- [ ] Add a test that changes the live same-spread position during location calculation and asserts no stale publish/didJump.
- [ ] Add a cancelled inverse test with no original locator and assert the live generation is poisoned and isolated.
- [ ] Run both and confirm stale commit and log-only recovery behavior.
- [ ] Increment viewport revisions on page-index/scroll/position-mutation changes and compare a full target stamp after calculation.
- [ ] Make missing-original-locator recovery call the fail-closed isolation path.
- [ ] Run focused tests.

### Task 6: Verification

**Files:**
- Verify only.

- [ ] Run all new regressions individually and confirm red-green behavior.
- [ ] Run `scripts/test.sh ReadiumNavigatorTests/NavigationOperationExecutorTests`.
- [ ] Run `scripts/test.sh ReadiumNavigatorTests/EPUBSpreadViewLifecycleTests`.
- [ ] Run the previously failing page-turn tests individually.
- [ ] Run `scripts/test.sh ReadiumNavigatorTests/EPUBPageTurnControllerTests`.
- [ ] Run `scripts/test.sh ReadiumNavigatorTests` if the focused suite is green.
- [ ] Run `git diff --check` and inspect the final diff for optional token, Bool compression, and unregistered detached-task regressions.
