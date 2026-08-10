#!/usr/bin/env bash
# =============================================================================
# test.sh [FILTER]
# =============================================================================
# Run the test suite.
#
# FILTER - Optional target to run (e.g. ReadiumSharedTests)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DESTINATION="platform=iOS Simulator,name=iPad (A16)"
FILTER="${1:-}"

ARGS=(
    -project "$REPO_ROOT/TestApp/TestApp.xcodeproj"
    -scheme TestApp
    -testPlan TestApp
    -destination "$DESTINATION"
    # UIKit/WebKit navigator suites share simulator process resources. Running
    # them in parallel can leave a page-turn transaction test stalled after an
    # unrelated suite and produces nondeterministic assertion failures.
    -parallel-testing-enabled NO
)
[ -n "$FILTER" ] && ARGS+=(-only-testing:"$FILTER")

xcodebuild test "${ARGS[@]}" 2> /dev/null | xcbeautify --quieter --disable-logging | grep -Ev "^Executed |Test Suite 'All tests'|Test run started\.|Test session results:"; true
