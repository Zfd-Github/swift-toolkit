# Page-Turn Recovery Ownership Design

## Goal

Prevent cancelled page-turn recovery from mutating or finishing a newer page-turn session, while preserving cancellation-safe restoration for unloaded EPUB spreads.

## Design

`EPUBNavigatorViewController` owns one recovery task identified by the original transaction session ID and a monotonically increasing generation. Recovery code verifies that ownership before and after every suspension point. A hard abort cancels the recovery task but retains its handle until the task exits; asynchronous and gesture-driven page-turn entry points drain that handle before opening a new session.

Transaction cleanup is scoped to the exact `PageTurnTransaction`. If hard abort has detached it, its runner may complete its own continuation but may not clear surfaces, release a new navigation lock, finish another active session, or resume pending gestures.

Fixed-layout spread navigation uses cancellation-aware Boolean waiters matching the reflowable contract. Cancellation, `clear()`, and load failure resume waiters with `false`; successful load resumes them with `true`.

For horizontal pagination, `waitForLoad: false` applies to every target index. A non-current target must already exist and accept the location synchronously before pagination changes the visible index; otherwise navigation returns `false` without moving.

TTS lifecycle tests assert the observable resource outcomes: engine speech continuation cancellation, forward-waiter removal, and successful continuation after pause/resume.

The repository formatter is run across the full tree because CI lints the full tree, including existing formatting debt.

## Verification

- Red/green targeted tests for recovery retirement, fixed-layout cancellation/clear, and adjacent not-ready pagination.
- Strengthened TTS lifecycle tests.
- `make lint-format`.
- Full `EPUBPageTurnControllerTests`, `PaginationViewTests`, `PublicationSpeechSynthesizerTests`, and `ReadiumNavigatorTests` with Xcode parallel workers disabled.
