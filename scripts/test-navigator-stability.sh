#!/usr/bin/env bash
# Runs ReadiumNavigatorTests repeatedly on one simulator with a per-run
# watchdog. The unit target includes a real interactive-deadline quiescence
# test which asserts executor/recovery/waiter/snapshot counters are all zero.
# Every iteration preserves xcodebuild's real exit status.

set -euo pipefail

ITERATIONS="${1:-10}"
WATCHDOG_SECONDS="${NAVIGATOR_TEST_WATCHDOG_SECONDS:-1200}"
DESTINATION="${NAVIGATOR_TEST_DESTINATION:-platform=iOS Simulator,name=iPad (A16)}"
SCHEME="${NAVIGATOR_TEST_SCHEME:-Readium-Package}"
QUIESCENCE_TEST_ID='EPUBPageTurnControllerTests/activeDeadlineReleasesInteractivePageTurnWaiter()'
RESULT_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/readium-navigator-stability.XXXXXX")"
trap 'rm -rf "$RESULT_DIRECTORY"' EXIT

if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
    echo "iterations must be a positive integer" >&2
    exit 64
fi

run_xcodebuild() {
    perl -e 'alarm shift; exec @ARGV' "$WATCHDOG_SECONDS" xcodebuild "$@"
}

assert_no_residual_test_processes() {
    local phase="$1"
    local pattern='/xctest($| )|/TestApp($| )|/NavigatorTestHost($| )'
    if pgrep -f "$pattern" >/dev/null; then
        echo "residual navigator test process found $phase" >&2
        pgrep -alf "$pattern" >&2
        exit 1
    fi
}

run_xcodebuild build-for-testing \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    | xcbeautify --quieter

for iteration in $(seq 1 "$ITERATIONS"); do
    assert_no_residual_test_processes "before run $iteration/$ITERATIONS"
    echo "Navigator stability run $iteration/$ITERATIONS"
    RESULT_BUNDLE="$RESULT_DIRECTORY/run-$iteration.xcresult"
    run_xcodebuild test-without-building \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -parallel-testing-enabled NO \
        -only-testing:ReadiumNavigatorTests \
        -resultBundlePath "$RESULT_BUNDLE" \
        | xcbeautify --quieter
    echo "Navigator internal quiescence check $iteration/$ITERATIONS"
    if ! xcrun xcresulttool get test-results tests \
        --path "$RESULT_BUNDLE" \
        --format json \
        | awk -v test_id="$QUIESCENCE_TEST_ID" '
            index($0, "\"nodeIdentifier\" : \"" test_id "\"") { found = 1 }
            found && /"result" : "Passed"/ { passed = 1 }
            END { exit !(found && passed) }
        '
    then
        echo "navigator internal quiescence test did not run or pass in run $iteration/$ITERATIONS" >&2
        exit 1
    fi
    assert_no_residual_test_processes "after run $iteration/$ITERATIONS"
done

echo "Navigator stability runs completed: $ITERATIONS/$ITERATIONS"
