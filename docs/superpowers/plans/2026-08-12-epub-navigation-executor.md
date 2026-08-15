# EPUB Navigation Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every EPUB reading-position mutation through one serial, deadline-bounded executor with end-to-end tokens, explicit results, verified success, and poisoned WebView replacement.

**Architecture:** A `@MainActor NavigationOperationExecutor` owns operation IDs, deadlines, coalescing, terminal arbitration, and recovery. `NavigationOperationToken` propagates through Navigator, PaginationView, PageView, EPUBSpreadView, and JavaScript evaluation; pagination and spread generations reject stale work. Timeout or WebContent loss poisons and detaches the old view before a replacement is restored to the last stable locator.

**Tech Stack:** Swift 6 concurrency, UIKit, WebKit, Swift Testing, XCTest, Xcodebuild.

## Global Constraints

- Preserve public Navigator Bool APIs; only `.applied` maps to `true`.
- Do not create or push a `codex/*` branch; work only on `hometail/readium-3.11`.
- Do not commit while the shared working tree contains the current uncommitted review fixes.
- Queue waiting time is included in the operation deadline.
- Recovery is an executor phase and may not acquire another executor lease.
- Timeout or WebContent termination after WebKit submission requires WebView generation replacement.
- Every continuation-based navigation wait must have success, cancellation, deadline, and generation-invalidated exits.

---

### Task 1: Operation model, one-shot waiter, and serial executor

**Files:**
- Create: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Create: `Sources/Navigator/EPUB/Navigation/NavigationOperationExecutor.swift`
- Test: `Tests/NavigatorTests/EPUB/NavigationOperationExecutorTests.swift`

**Interfaces:**
- Produces `NavigationResult`, `NavigationValueResult<Value>`, `NavigationOperationIntent`, `NavigationOperationToken`, `NavigationOperationExecutor.submit(intent:timeout:operation:)`.
- Executor exposes testing diagnostics: active count, maximum active count, pending count, waiter count, and last operation ID.

- [ ] Write tests proving operation IDs increase, only one body runs, absolute/reload requests are latest-wins, relative queue is bounded, queued deadlines expire, and every request completes exactly once.
- [ ] Run `ReadiumNavigatorTests/NavigationOperationExecutorTests`; confirm failures because the types do not exist.
- [ ] Implement token terminal arbitration, absolute deadline checking, cancellation/supersession, intent-aware queue replacement, and one-shot request continuations.
- [ ] Re-run the executor tests and confirm all pass.

### Task 2: Token-aware waits and explicit PageView/Pagination results

**Files:**
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Modify: `Tests/NavigatorTests/Toolkit/PaginationViewTests.swift`
- Modify: `Sources/Navigator/EPUB/EPUBFixedSpreadView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift`
- Modify: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- `PageView.go(to:animated:waitForLoad:operation:) async -> NavigationResult`.
- `PaginationView.goToIndex(_:location:options:waitForLoad:operation:) async -> NavigationResult`.
- `PaginationView.generation` increases on reload/replacement and token binding verifies it.

- [ ] Add failing tests for superseded page load, page-ready timeout, scroll animation timeout, stale pagination generation, and JavaScript failure propagation through `goToIndex`.
- [ ] Convert PageView and PaginationView navigation methods to return `NavigationResult`; remove discarded results from load and scroll paths.
- [ ] Wrap vertical readiness and animation waits with operation/deadline/generation exits.
- [ ] Add target-index validation before returning `.applied`.
- [ ] Run PaginationView and PageTurn tests; confirm all pass.

### Task 3: Spread/WebView generation and token-aware JavaScript

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBSpreadView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBFixedSpreadView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift`
- Modify: `Tests/NavigatorTests/EPUB/EPUBSpreadViewLifecycleTests.swift`

**Interfaces:**
- `EPUBSpreadView.spreadGeneration`, `webViewGeneration`, `isPoisoned`.
- `evaluateScript(_:inHREF:operation:) async -> NavigationValueResult<Any>`.
- `poison(operation:reason:)` resolves load/script/go/scroll waiters and rejects later callbacks.

- [ ] Add failing tests for deadline covering spread load, script failure, never-callback timeout, late callback, stale operation token, clear, and termination.
- [ ] Bind each request to operation/spread/WebView generations and use the operation's remaining deadline rather than a new local timeout.
- [ ] Make script callbacks one-shot and reject mismatched generations.
- [ ] Convert fixed/reflowable go and scroll completion waiters to token-aware explicit results.
- [ ] Run lifecycle and PageTurn tests; confirm all pass.

### Task 4: Route direct and relative navigation through executor

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Navigator owns one `NavigationOperationExecutor`.
- Internal `performNavigation(intent:token:) async -> NavigationResult` maps public Bool only at the boundary.
- Stable locator is updated only after target verification.

- [ ] Add failing tests for simultaneous locator jumps, relative command ordering, operation A timeout followed by B, failure without location publication, and explicit same/cross-spread verification failure.
- [ ] Route locator/link/forward/backward through executor and propagate token to PaginationView.
- [ ] Verify href plus progression/position/fragment before `.applied` and before callbacks.
- [ ] Delete the temporary recovery-drain lease from public navigation once executor serialization replaces it.
- [ ] Run PageTurn and Pagination tests; confirm all pass.

### Task 5: Single page-turn and recovery state machine

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/EPUB/PageTurn/EPUBPageTurnController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Page-turn prepare/commit/reverse execute inside the active token.
- `recoverNavigation(operation:originalLocator:)` performs inverse, verified locator restore, replacement reload, bounded failure in order.

- [ ] Add failing tests for recovery hard abort, recovery plus locator jump, repeated reverse plus external cancellation, and maximum one mutation body.
- [ ] Remove independent page-turn recovery/hard-abort restore Tasks and make them executor-owned phases.
- [ ] Propagate token through preview, location calculation, display-frame, commit, reverse, and reload verification waits.
- [ ] Ensure each transaction and executor request has one terminal result and final idle/error state.
- [ ] Run PageTurn tests twice consecutively; confirm both pass.

### Task 6: Poison, detach, replacement, and stable-locator restore

**Files:**
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/EPUB/EPUBSpreadView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBSpreadViewLifecycleTests.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- `PaginationView.detachPoisonedView(_:at:operation:)` increments generation and removes it from the hierarchy.
- Executor recovery creates a new spread through the existing pagination delegate and verifies a newer WebView generation at stable locator.

- [ ] Add failing tests for timeout then late old callback, operation B after A timeout, termination during load/script/scroll/recovery, and old-generation location callback after reload.
- [ ] Mark untrusted spread generation poisoned, stop and resolve it, detach it, and increment pagination generation before releasing the lease.
- [ ] Create replacement spread/WKWebView, restore stable locator, verify new generation and target, then publish.
- [ ] Return bounded failure and explicit navigator error if replacement misses the operation deadline.
- [ ] Run lifecycle, PaginationView, and PageTurn tests; confirm all pass.

### Task 7: Route reload, preferences, layout, and WebContent termination

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewModel.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Reload/preferences/layout mutations submit latest-wins executor intents.
- `spreadViewDidTerminate(_:)` identifies the spread generation and signals the active executor operation; it does not directly call `reloadSpreads()`.

- [ ] Add failing tests for preference reload coalescing, layout reload concurrent with jump, and termination-triggered replacement.
- [ ] Route snapshot-delayed reload, preference pagination replacement, activation reload, size/layout reload, and termination through executor.
- [ ] Reject stale ViewModel and spread callbacks using pagination/spread generations.
- [ ] Run all Navigator tests; confirm pass.

### Task 8: Continuation audit and script exit status

**Files:**
- Modify: `scripts/test.sh`
- Modify navigation files containing raw continuations identified by `rg`.
- Add or modify the nearest owning test suite for every converted waiter.

**Interfaces:**
- Test script returns the real `xcodebuild`/pipeline status.
- Navigation code contains no raw continuation without token/generation/deadline lifecycle ownership.

- [ ] Add a shell regression that runs a deliberately invalid `-only-testing` target or failing command and asserts non-zero status.
- [ ] Remove `; true` and preserve `pipefail` through xcbeautify/filtering.
- [ ] Audit `rg -n 'with(Check|Unsafe).*Continuation' Sources/Navigator/EPUB Sources/Navigator/Toolkit/PaginationView.swift`; wrap every navigation-relevant occurrence in one-shot lifecycle ownership.
- [ ] Run formatter, continuation audit, and targeted tests.

### Task 9: Ten-run watchdog verification

**Files:**
- Create: `scripts/test-navigator-stability.sh`

**Interfaces:**
- Script runs ten serial Navigator suites on one selected simulator, applies a per-run outer watchdog, records real exit codes, and audits residual processes/diagnostics.

- [ ] Implement the script with `perl` or a shell watchdog available on macOS, one simulator destination, ten iterations, and per-run result summaries.
- [ ] After each iteration, fail if an unexpected repository-owned xctest remains or executor diagnostics report active operation/waiter/recovery counts.
- [ ] Run `Readium-Package build-for-testing`.
- [ ] Run targeted executor, lifecycle, PaginationView, PageTurn, and complete Navigator suites.
- [ ] Run the ten-iteration stability script to completion.
- [ ] Run `make lint-format`, `git diff --check`, and inspect final process state.
