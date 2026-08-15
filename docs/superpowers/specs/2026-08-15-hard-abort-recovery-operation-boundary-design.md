# Hard-Abort Recovery Operation Boundary Design

## Problem

An executor-owned navigation can suspend before acquiring the page-turn lease. If selection clear synchronously reserves a mandatory hard-abort recovery while that navigation is active, the global `hardAbortLocationRestorePending` flag makes the active navigation wait for work queued behind itself. The recovery cannot start until the active operation releases the executor, so both sides wait until the active operation deadline isolates it.

The existing selection-clear regression returns `nil` from link resolution and therefore exits before `performLocatorNavigation` reaches the operation-aware lease wait.

## State Model

Every hard-abort reservation is tracked by its executor `operationID` until its completion callback delivers a terminal `NavigationResult`. Tracking is per reservation, not a latest-ID flag. The pending collection is the source of truth for pending state, diagnostics, teardown, and waiter decisions.

Each operation-aware waiter snapshots the IDs strictly older than its current operation ID. It waits only for those dependencies. A later reservation never joins an existing wait and cannot delay the active operation. Terminal results from the dependencies are propagated precisely; failures such as `.timedOut`, `.cancelled`, or `.spreadNotLoaded` are not converted to `.applied`.

Ordinary gesture/session entry points have no executor ordering token and continue to drain every hard-abort recovery, including recoveries added while they wait.

## Ordering

- Active A followed by C: A ignores C because `C.operationID > A.operationID`; executor order is A then C.
- Active A followed by C1 and C2: A ignores both; mandatory recovery queue categories preserve C1 then C2.
- Pending/active C followed by D: D sees C as older and waits; executor also schedules C before D.
- An operation-aware waiter with several older recoveries returns when all of its captured older IDs terminate, even if newer recoveries are submitted meanwhile.

## Lifecycle and Teardown

Reservation registration and pending-state insertion occur synchronously in the same `MainActor` turn. Completion records the exact terminal result, removes the reservation from pending state, and resumes only waiters that depended on that ID. The ordinary drain continues until the pending collection is empty. Cancellation, queued deadline expiry, active deadline expiry, and owner teardown all flow through the reservation completion path so no pending ID or continuation remains stranded.

## Verification

The primary regression uses a valid locator and a mutation seam to prove A enters `performLocatorNavigation`. It synchronously reserves C while A is active, verifies A completes well below 15 seconds without isolation or pagination-generation replacement, then verifies C executes and all executor/recovery diagnostics reach zero.

Additional tests cover A with C1/C2 FIFO, the inverse C-before-D boundary, and precise propagation of non-applied recovery terminal results. Review covers reservation lifecycle, multi-recovery ordering, cancellation/deadline behavior, owner teardown, and final quiescence.
