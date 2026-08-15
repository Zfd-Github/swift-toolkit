# Hard-Abort Recovery Operation Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent executor-owned navigation from waiting for later hard-abort recovery reservations while preserving older-recovery ordering and exact terminal-result propagation.

**Architecture:** Replace the single global pending/waiter decision with per-reservation state keyed by executor operation ID. Operation-aware waits capture and drain only older IDs; ordinary waits drain the complete live set. Executor FIFO remains the sole ordering mechanism for later mandatory recovery work.

**Tech Stack:** Swift 5.10, Swift Concurrency, Swift Testing, UIKit, iOS Simulator.

## Global Constraints

- Keep all Hometail changes on `hometail/readium-3.11`; do not create or use `codex/*` branches.
- Preserve unrelated dirty-worktree changes.
- Use CodeGraph first for structural navigation and `apply_patch` for edits.
- Observe a failing regression before changing production behavior.
- Propagate `.timedOut`, `.cancelled`, `.spreadNotLoaded`, and other non-applied terminal results exactly.

---

### Task 1: Reproduce the later-recovery cycle

**Files:**
- Modify: `Tests/NavigatorTests/EPUB/PageTurnHardAbortTests.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift` only for read-only testing diagnostics that cannot alter behavior.

**Interfaces:**
- Consumes: `go(to:options:)`, `linkLocatorForTesting`, `pageTurnGoToIndexForTesting`, selection-clear delegate path, navigation diagnostics.
- Produces: a regression proving a valid locator reaches locator mutation while C is synchronously reserved behind active A.

- [ ] **Step 1: Write the failing regression**

Use a valid same-publication locator. Suspend the active operation at `pageTurnGoToIndexForTesting`, synchronously call selection clear, release A, and bound completion with a sub-second test deadline. Assert A entered mutation, did not isolate, did not replace the pagination generation, then assert recovery snap and exact final quiescence.

- [ ] **Step 2: Verify RED**

Run `scripts/test.sh 'ReadiumNavigatorTests/PageTurnHardAbortTests/selectionClearQueuesSnapBehindExecutorNavigation()'` and confirm it fails because A waits until its executor deadline/isolation rather than completing normally.

### Task 2: Track recovery reservations by operation ID

**Files:**
- Modify: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`

**Interfaces:**
- Produces: `NavigationOperationReservation.operationID` and per-ID hard-abort recovery state with exact terminal results.

- [ ] **Step 1: Expose the reserved operation ID**

Return the assigned `operationID` with `NavigationOperationReservation` so the navigator can insert state synchronously before another MainActor turn.

- [ ] **Step 2: Replace global recovery state**

Track every nonterminal hard-abort reservation by ID. Completion removes only its own ID, stores/delivers its exact result, and resumes only dependent waiters. Derive global pending diagnostics from the collection.

- [ ] **Step 3: Implement boundary waits**

For an operation token, capture IDs `< operation.operationID` and await those IDs only. Do not add newer reservations to that waiter. For ordinary waits, continue draining until the entire collection is empty.

- [ ] **Step 4: Verify GREEN**

Re-run the primary regression and confirm it passes without a 15-second timeout.

### Task 3: Cover multiple reservations and inverse ordering

**Files:**
- Modify: `Tests/NavigatorTests/EPUB/PageTurnHardAbortTests.swift`

**Interfaces:**
- Produces: regressions for A → C1 → C2 and C → D ordering, exact result propagation, and zero residual state.

- [ ] **Step 1: Add A/C1/C2 regression**

Hold A in locator mutation, synchronously reserve C1 and C2, release A, and assert strict execution order `A`, `C1`, `C2`, maximum one active mutation, and final zero diagnostics.

- [ ] **Step 2: Add C-before-D regression**

Hold C, submit D, and assert D cannot enter mutation before C finishes; then assert `C`, `D` and final quiescence.

- [ ] **Step 3: Add terminal-result regression where needed**

Exercise a failing older recovery and assert an operation-aware waiter receives that exact non-applied result rather than `.applied`.

- [ ] **Step 4: Run the complete hard-abort suite**

Run `scripts/test.sh 'ReadiumNavigatorTests/PageTurnHardAbortTests'`.

### Task 4: Review and full verification

**Files:**
- Review: `Sources/Navigator/EPUB/Navigation/NavigationOperation.swift`
- Review: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Review: `Tests/NavigatorTests/EPUB/PageTurnHardAbortTests.swift`

- [ ] **Step 1: Request independent review**

Review reservation registration/completion, multiple recovery FIFO, cancellation/deadline, owner teardown, continuation single-resume safety, and final quiescence. Fix every Critical and Important issue, plus relevant Minor correctness/test gaps.

- [ ] **Step 2: Run focused suites**

Run `NavigationOperationExecutorTests`, `PageTurnHardAbortTests`, `EPUBPageTurnControllerTests`, and `EPUBSpreadViewLifecycleTests`.

- [ ] **Step 3: Run stability and diff checks**

Run `scripts/test-navigator-stability.sh 10` and `git diff --check`.
