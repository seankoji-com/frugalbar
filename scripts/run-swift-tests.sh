#!/usr/bin/env bash
#
# run-swift-tests.sh — run the whole test suite as two `swift test`
# invocations, then check that together they selected all of it.
#
# DeadlineUncancellableTests time withDeadline against the wall clock: a 0.2s
# deadline must return within 1.5s while a thread sleeps for 3s, and 0.05s of
# blocking work must beat a 2s deadline. Both depend on the concurrency pool
# reaching the timeout and work tasks promptly. In the main --parallel run that
# pool (one thread per core) is shared with every other test. The suite flaked
# there on hosted CI (green runs took 0.76s and 1.03s, red ones 1.82s and over
# 2s), and those logs are consistent with it waiting in that queue, though
# general host contention would look the same and a repeated isolated-versus-
# full comparison under load has not been run. Here the suite gets a process of
# its own and the rest of the suite runs in parallel as before. No assertion is
# changed and nothing is retried.
#
# Both invocations use one regex, as --filter and as --skip, so they cannot
# overlap or leave a gap. `swift test list` then proves the regex selects at
# least one test and not every test, and each run must report exactly its
# listed count (swift-testing counts trait-skipped tests as run), so together
# they ran the whole suite and a renamed suite cannot silently run nothing.
#
# Coverage: SwiftPM clears its coverage data at the start of each invocation,
# so with --enable-code-coverage the report is the second (main) invocation's.
#
# Usage:
#   scripts/run-swift-tests.sh [--enable-code-coverage]

set -uo pipefail

isolated='DeadlineUncancellableTests'
args=(-c debug "$@")
logs=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-tests.XXXXXX")
status=0

fail() {
  echo "::error::run-swift-tests: $*" >&2
  status=1
}

# N from swift-testing's "Test run with N tests [in M suites] passed|failed".
ran() {
  sed -nE 's/.*Test run with ([0-9]+) tests?( in [0-9]+ suites?)? (passed|failed).*/\1/p' "$1" | tail -n 1
}

echo "==> isolated: --filter $isolated"
swift test "${args[@]}" --filter "$isolated" 2>&1 | tee "$logs/isolated.log" \
  || fail "isolated invocation failed"

echo "==> parallel: --skip $isolated"
swift test "${args[@]}" --parallel --skip "$isolated" 2>&1 | tee "$logs/parallel.log" \
  || fail "parallel invocation failed"

# --skip-build lists the binary just built rather than rebuilding without the
# caller's flags; an instrumented binary would otherwise drop default.profraw
# into the checkout.
if ! LLVM_PROFILE_FILE="$logs/list-%p.profraw" \
    swift test list -c debug --skip-build > "$logs/list.txt" 2> "$logs/list.err"; then
  cat "$logs/list.err" >&2
  fail "swift test list failed"
fi

total=$(grep -c . "$logs/list.txt")
selected=$(grep -cE "$isolated" "$logs/list.txt")
remaining=$((total - selected))
ran_isolated=$(ran "$logs/isolated.log")
ran_parallel=$(ran "$logs/parallel.log")

echo "==> listed $total tests: $selected isolated, $remaining in the parallel run"
echo "==> isolated run reported ${ran_isolated:-no} tests; parallel run reported ${ran_parallel:-no} tests"

[ "$selected" -ge 1 ] || fail "'$isolated' matches no listed test; the isolated run would test nothing"
[ "$remaining" -ge 1 ] || fail "'$isolated' matches every listed test"
[ "${ran_isolated:-}" = "$selected" ] \
  || fail "isolated run reported ${ran_isolated:-no} tests, expected the $selected listed"
[ "${ran_parallel:-}" = "$remaining" ] \
  || fail "parallel run reported ${ran_parallel:-no} tests, expected the $remaining listed"

exit "$status"
