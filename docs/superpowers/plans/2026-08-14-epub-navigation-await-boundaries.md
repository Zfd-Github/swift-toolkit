# EPUB Navigation Await-Boundary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every asynchronous EPUB navigation continuation re-proves operation/generation ownership before mutating state, and make publication the final synchronous commit point.

**Architecture:** Executor-owned work carries a non-optional `NavigationOperationToken` through every mutation-capable await. Pagination transitions additionally bind the captured pagination generation, while non-executor initialization work uses a captured reload generation. Publication validates the calculated target immediately before a synchronous commit; cleanup and snapshot barriers occur before publication or inside a bounded executor operation.

**Tech Stack:** Swift 5.10, UIKit, Swift Concurrency, Swift Testing, iOS Simulator.

## Global Constraints

- Keep all Hometail changes on `hometail/readium-3.11`; do not create or use `codex/*` branches.
- Preserve unrelated dirty-worktree changes.
- Use CodeGraph first for structural navigation and `apply_patch` for edits.
- Each production change requires a failing regression test observed before implementation.
- No optional navigation token or TaskLocal fallback may be introduced.

---

### Task 1: Token- and generation-aware pagination transitions

**Files:**
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift:1018-1510`
- Test: `Tests/NavigatorTests/Toolkit/PaginationViewTests.swift`

**Interfaces:**
- Consumes: `NavigationOperation.check(paginationGeneration:)` and `PaginationView.generation`.
- Produces: token-aware `slideToView`, `fadeToView`, and vertical-navigation results that reject late continuations before any state mutation.

- [ ] **Step 1: Write the failing fade regression**

Add `expiredFadeDoesNotSelectTargetAfterContinuationResumes()`: start a non-adjacent animated `goToIndexWithMutation` with a 20 ms token deadline, await the 150 ms fade continuation, and assert `currentIndex` remains the original index.

- [ ] **Step 2: Run the test and verify RED**

Run `scripts/test.sh 'ReadiumNavigatorTests/PaginationViewTests/expiredFadeDoesNotSelectTargetAfterContinuationResumes()'`.

Expected: FAIL because the legacy `scrollToView` changes `currentIndex` after the token has expired.

- [ ] **Step 3: Make horizontal transitions operation-aware**

Pass `NavigationOperationToken` and captured pagination generation into `slideToView` and `fadeToView`. Check ownership after every animation/sleep await and before `setCurrentIndex`, scroll interaction changes, or loading-queue mutations. Return a `NavigationResult` to `goToIndexWithMutation`; remove the unowned `scrollToView` path. Isolation must cancel layer animations and restore view alpha synchronously.

- [ ] **Step 4: Add vertical late-continuation regression**

Add `expiredVerticalOffsetResolutionDoesNotCommitTarget()`: suspend the delegate offset resolver, expire/cancel the operation, resume the resolver, and assert neither `currentIndex` nor the viewport offset changes.

- [ ] **Step 5: Make vertical navigation generation-aware**

Provide an explicit token-aware vertical entry point for executor navigation and a reload-generation-aware initialization entry point. Both must check validity after page readiness, offset resolution, and animation awaits before committing index/offset or scheduling viewport updates.

- [ ] **Step 6: Verify GREEN**

Run `scripts/test.sh 'ReadiumNavigatorTests/PaginationViewTests'`.

Expected: PASS.

### Task 2: Make surface publication terminal

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift:3013-3175`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `publishPageTurnLocation(_:operation:)`.
- Produces: relative surface commit with no await or negative ownership check after successful publication.

- [ ] **Step 1: Write the failing publication-window regression**

Add `relativeSurfaceDeadlineAfterPublicationStillReturnsSuccess()`: allow a relative cover/push turn to publish, block the following frame waiter past the executor deadline, and assert the public navigation result remains true with exactly one location notification.

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because the executor returns `.timedOut` after publication.

- [ ] **Step 3: End the operation synchronously after publication**

For relative surface turns, make successful `publishPageTurnLocation` the final irreversible point: synchronously mark cleanup, finish the session, and return success. Keep all frame and surface-identity verification before publication.

- [ ] **Step 4: Verify GREEN**

Run the new test and the existing surface commit/cancellation tests.

### Task 3: Bound begin drains and hard-abort snapping

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift:1125-1390`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `awaitPageTurnNavigationLease(operation:)`.
- Produces: `beginPageTurn(to:operation:) -> NavigationValueResult<PageTurnSession>` and executor-owned hard-abort snapping.

- [ ] **Step 1: Write the failing begin-drain regression**

Add `expiredBeginDrainCannotOpenLateSession()`: block hard-abort restore, begin with an explicit operation, cancel/expire it, resume restore, and assert no page-turn session opens.

- [ ] **Step 2: Run and verify RED**

Expected: compile/runtime failure because executor page turns still call the unowned begin drain.

- [ ] **Step 3: Add the token-aware begin path**

Make `runPageTurn` and `turnWithPageSurface` call `beginPageTurn(to:operation:)`. Check the result after each recovery/hard-abort drain and immediately before `openPageTurnSession`.

- [ ] **Step 4: Write the hard-abort snap ownership regression**

Add `hardAbortSnapRunsInsideExecutorLease()` and assert the snap occurs while the restore executor request is active.

- [ ] **Step 5: Move snap into the executor body**

Perform `snapVisibleDocumentToPageBoundaries()` synchronously after successful restore/recovery, after confirming there is no newer restore request and before returning from the executor body. Remove the worker's post-submit snap.

- [ ] **Step 6: Verify GREEN**

Run the begin/hard-abort tests plus the full page-turn controller suite.

### Task 4: Validate the exact calculated locator target

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift:5970-6105`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: requested normalized locator, calculated locator, live pagination/spread revision stamp.
- Produces: exact target matcher for progression, position, fragment/CSS/DOM anchors and a target-preserving committed locator.

- [ ] **Step 1: Write the failing same-href/wrong-progression regression**

Add `locatorPublicationRejectsWrongCalculatedProgression()`: verify a target progression in the live-view seam, return a different progression from the calculation seam without changing viewport revision, and assert no publish and no `didJumpTo`.

- [ ] **Step 2: Run and verify RED**

Expected: FAIL because href and revision currently pass.

- [ ] **Step 3: Implement target validation**

Before publication, compare calculated progression/position to the resolved target using the same pagination reachability rules as live verification. Preserve verified fragment, CSS selector, DOM range, and text-highlight anchors in the committed locator. For DOM-only targets, repeat exact visibility verification after calculation, then re-check the revision stamp; leave no await between the final stamp check and publication.

- [ ] **Step 4: Verify GREEN**

Run locator navigation tests, including viewport-revision and position-only cases.

### Task 5: Capture stable locator before timeout retirement

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift:348-365`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: transaction original locator, surface original preview, published current location.
- Produces: deferred poisoned-pagination recovery seeded from the most precise pre-retirement locator.

- [ ] **Step 1: Write the failing stable-preview regression**

Add `timeoutIsolationPreservesExactOriginalPreview()`: arrange a surface original preview with a CSS/fragment anchor richer than `currentLocation`, trigger timeout isolation, then assert poison recovery uses that exact anchor.

- [ ] **Step 2: Run and verify RED**

Expected: FAIL because retirement clears both richer sources before they are read.

- [ ] **Step 3: Capture before retirement**

Compute `stableLocator` before `retireAbandonedPageTurn`, then seed `deferredPoisonedPaginationReplacement` from that captured value.

- [ ] **Step 4: Verify GREEN**

Run the new test and expired-poison recovery tests.

### Task 6: Bound public settle snapshot restoration

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift:5746-5805`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Consumes: `EPUBPageTurnSnapshotProvider.settle(operation:)`.
- Produces: `settlePageTurn()` whose snapshot barrier shares the executor's absolute deadline.

- [ ] **Step 1: Write the failing public-settle regression**

Add `settlePageTurnDeadlineDoesNotWaitForeverForSnapshotRestore()`: hold capture restoration after cancellation, set a 20 ms navigation timeout, call public settle, and assert it returns while the capture lease remains isolated; then release restoration for cleanup.

- [ ] **Step 2: Run and verify RED**

Expected: FAIL/hang until the test gate is opened because public settle calls unbounded `snapshotProvider.settle()`.

- [ ] **Step 3: Move snapshot settle under the executor deadline**

Call `snapshotProvider.settle(operation:)` at the start of the settle recovery executor body and reject before recovery/publication if it times out. Remove the final unowned settle call.

- [ ] **Step 4: Verify GREEN**

Run controller snapshot-barrier tests and `EPUBPageTurnSnapshotTests`.

### Task 7: Full asynchronous-boundary audit and verification

**Files:**
- Review: `Sources/Navigator/Toolkit/PaginationView.swift`
- Review: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Review: `Sources/Navigator/EPUB/PageTurn/EPUBPageTurnSnapshotProvider.swift`

- [ ] **Step 1: Audit every mutation-capable await**

Check that every await followed by a state write has either an operation/generation validation or operates only on a detached generation. Check that no successful publication is followed by an await that can negate success.

- [ ] **Step 2: Run focused suites**

Run `PaginationViewTests`, `NavigationOperationExecutorTests`, `EPUBPageTurnSnapshotTests`, `EPUBSpreadViewLifecycleTests`, and `EPUBPageTurnControllerTests`.

- [ ] **Step 3: Run full Navigator tests**

Run `scripts/test.sh ReadiumNavigatorTests`.

- [ ] **Step 4: Run formatting and diff checks**

Run `make lint-format` and `git diff --check`.

