# EPUB Navigation P1 Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep animated locator scrolling and poisoned-generation replacement fully inside executor ownership, and verify every continuous-scroll DOM target against the outer viewport.

**Architecture:** Reuse the existing reflowable scroll-settle waiter for every animated position mutation. Split poisoned recovery into synchronous generation isolation plus a deferred replacement marker; only start `reloadAtIndex` after a live operation confirms remaining budget, and re-isolate if that budget expires. Treat progression, position, fragment, CSS selector, and text highlight as within-resource vertical targets.

**Tech Stack:** Swift 6, UIKit, WebKit, Swift Testing, Xcode test plans.

## Global Constraints

- Keep all Hometail changes on `hometail/readium-3.11`.
- Do not create, use, or push `codex/*` branches.
- Preserve the executor's original absolute deadline.
- Every production change follows a red-green test cycle.

---

### Task 1: Animated locator scroll ownership

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `EPUBReflowableSpreadView.go(to:animated:waitForLoad:operation:)`
- Produces: all animated locator branches return only after `scrollDidEnd`, cancellation, or the operation deadline.

- [x] Add a real navigator test which starts a same-resource animated locator jump and asserts the navigation task remains incomplete before the scroll settles.
- [x] Run the focused test and confirm it fails because the task returns immediately after the JavaScript callback.
- [x] Route successful animated `scrollToPosition`, `scrollToId`, and `scrollToLocator` results through the deadline-aware scroll animation waiter.
- [x] Make waiter cancellation/timeout retire and poison the active WebView generation.
- [x] Run the focused test and existing spread lifecycle tests.

### Task 2: Deferred poisoned pagination replacement

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`
- Test: `Tests/NavigatorTests/Toolkit/PaginationViewTests.swift`

**Interfaces:**
- Produces: `PaginationView.isolateForDeferredReload()` synchronously invalidates loading generations and removes live pages.
- Produces: navigator-owned deferred replacement state carrying the stable locator.

- [x] Add a timeout recovery test asserting no replacement view appears after the expired executor lease.
- [x] Add a follow-up request assertion proving the next operation replaces the isolated pagination before navigating.
- [x] Run the focused test and confirm the current unconditional `reloadAtIndex` violates it.
- [x] Isolate poisoned generations synchronously and store the stable locator before any await.
- [x] Check the operation before `reloadAtIndex`; when no budget remains, return with the deferred marker intact.
- [x] If deadline/cancellation occurs after reload begins, call `isolateForDeferredReload()` before releasing the executor.
- [x] Clear the marker only after replacement is loaded and verified.
- [x] Run the focused recovery and PaginationView tests.

### Task 3: Continuous-scroll DOM target verification

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `PaginationView.isAtVerticalLocation(_:at:tolerance:)`
- Produces: every locator with progression, position, fragment, CSS selector, or text highlight uses outer-Y verification in vertical continuous mode.

- [x] Add fragment-only, CSS-selector-only, and text-highlight-only cases to the single-width vertical verification test.
- [x] Run the focused test and confirm those cases currently return true without consulting the outer verifier.
- [x] Add one within-resource-target predicate covering all supported DOM and numeric anchors.
- [x] Route all such targets through `isAtVerticalLocation`.
- [x] Run the focused test and locator verification suite.

### Task 4: Verification

**Files:**
- Verify only.

- [x] Run the three focused regressions.
- [x] Run `scripts/test.sh ReadiumNavigatorTests`.
- [x] Run `scripts/test-navigator-stability.sh 1`.
- [x] Run `git diff --check` and confirm no old unconditional recovery reload path remains.

### Task 5: Bind animated locator settlement to its own mutation

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: a request-scoped animated locator settle state which cannot be completed by an unscoped prior debounce callback.
- Consumes: final target geometry for progression, fragment, CSS selector, and text locators.

- [x] Add a deterministic regression which delivers an old unscoped settle signal before the new mutation starts moving and asserts the new operation remains pending.
- [x] Add a zero-displacement case which succeeds only when final target geometry already matches.
- [x] Run both cases and confirm the current waiter finishes early or times out.
- [x] Require observed movement before quiet-window settlement; remove unscoped completion of request-owned waiters.
- [x] Allow no-movement completion only after final target verification succeeds.
- [x] Run the animated locator regression repeatedly.

### Task 6: Repair cold cross-resource simulation preparation

**Files:**
- Modify: `Sources/Navigator/EPUB/PageTurn/EPUBPageTurnController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `PageTurnTransaction`, snapshot provider, executor lease, and cold target pagination loading.
- Produces: a mounted curl render view during the first cold cross-resource interactive swipe, followed by exactly one committed location publish.

- [x] Reproduce the exact test in isolation and confirm no curl render view is mounted within five seconds.
- [x] Record transaction preparation stage, executor state, snapshot state, and cold-navigation evidence at the failure boundary.
- [x] Trace the first blocking state transition back to its owner and add a minimal failing assertion for that contract.
- [x] Mount the simulated reader hierarchy in a visible test window and mount the current-page curl before target capture, so gesture tracking is independent of cold WebKit load latency.
- [x] Run the exact test three consecutive times, the full controller suite, and the full Navigator target.
