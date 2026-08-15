# Page-Turn Recovery Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make EPUB page-turn recovery transaction-owned and cancellation-safe, close fixed-layout and pagination readiness gaps, strengthen TTS lifecycle coverage, and restore formatting CI.

**Architecture:** `EPUBNavigatorViewController` stores a recovery task with transaction session ID and generation, cancels but drains it across hard abort, and gates all post-await mutations on ownership. Page views return an actual Boolean application result; fixed and reflowable waiters share cancellation semantics, while non-waiting horizontal navigation refuses unready targets before changing the visible index.

**Tech Stack:** Swift 6, Swift Concurrency, UIKit/WebKit, Swift Testing, XCTest, SwiftFormat, XcodeBuild.

## Global Constraints

- Work only on `hometail/readium-3.11`; do not create or push `codex/*` branches.
- Preserve unrelated worktree changes.
- Use deterministic gates and conditions instead of sleeps in new race tests.
- Do not commit or push unless requested by the user.

---

### Task 1: Transaction-owned recovery

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: navigator-owned recovery task keyed by `PageTurnSession.id` and generation.
- Enforces: hard abort cancels recovery; new page-turn entry drains recovery; old runner cleanup is transaction-scoped.

- [ ] Write a gated test that hard-aborts an old recovery, requests a new turn, releases the old gate, and proves the old runner cannot finish the new session.
- [ ] Run the test against current code and verify the ownership/idle assertion fails.
- [ ] Add recovery ownership state, pre/post-await guards, hard-abort cancellation, entry-point draining, and exact-transaction cleanup guards.
- [ ] Run the targeted test and existing cancellation recovery tests.

### Task 2: Fixed-layout waiter lifecycle

**Files:**
- Modify: `Sources/Navigator/EPUB/EPUBFixedSpreadView.swift`
- Test: `Tests/NavigatorTests/EPUB/EPUBPageTurnControllerTests.swift`

**Interfaces:**
- Produces: `go(to:animated:waitForLoad:) async -> Bool` that returns `false` on task cancellation or `clear()` and `true` only after `spreadDidLoad()`.

- [ ] Write real fixed-spread tests for task cancellation and `clear()` while waiting.
- [ ] Run them against current code and verify they time out or remain incomplete.
- [ ] Replace raw continuations with one-shot Boolean waiters and drain them from `clear()` and `spreadDidLoad()`.
- [ ] Run fixed-layout and page-turn suites.

### Task 3: Non-waiting adjacent pagination

**Files:**
- Modify: `Sources/Navigator/Toolkit/PaginationView.swift`
- Test: `Tests/NavigatorTests/Toolkit/PaginationViewTests.swift`

**Interfaces:**
- Enforces: `waitForLoad: false` returns `false` and preserves `currentIndex` when an adjacent/far target cannot immediately apply its location.

- [ ] Add an adjacent suspended-page test asserting `false` and unchanged index.
- [ ] Run it against current code and verify it fails because the index changes and the call returns `true`.
- [ ] Pre-apply the location to an existing target page with `waitForLoad: false` before slide/fade; reject absent or unready targets.
- [ ] Run all PaginationView tests.

### Task 4: TTS lifecycle assertions

**Files:**
- Modify: `Tests/NavigatorTests/TTS/PublicationSpeechSynthesizerTests.swift`

**Interfaces:**
- Verifies: deinit cancels pending speech; stop/pause remove forward waiters; resume restarts paused utterance and continues playback.

- [ ] Strengthen speech-release test to wait for `engine.hasPendingSpeech == false`.
- [ ] Strengthen stop/pause tests to wait for `isWaitingForForwardPrefetchForTesting == false`.
- [ ] Extend pause test through resume and subsequent speech continuation.
- [ ] Run the targeted lifecycle tests and full TTS suite.

### Task 5: Formatting and final verification

**Files:**
- Modify: all files reported by SwiftFormat lint.

**Interfaces:**
- Produces: a tree accepted by the configured `make lint-format` CI job.

- [ ] Run `make format` and inspect the resulting diff for semantic changes.
- [ ] Run `make lint-format` and require exit code 0.
- [ ] Run `git diff --check`.
- [ ] Run full PageTurn, Pagination, TTS, and ReadiumNavigator test suites with `-parallel-testing-enabled NO`.
