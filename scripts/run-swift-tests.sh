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
# Both invocations use the same regex as --filter and --skip, so they select
# complementary parts of the suite. `swift test list` confirms the suite still
# exists and is not the whole suite. Its output expands parameterized cases,
# while the test-run summary counts logical tests, so those counts are not
# comparable.
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
trap 'rm -rf -- "$logs"' EXIT
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

# Listing builds the test executable when needed. Keep any coverage output out
# of the checkout, including when this is the first command after a clean build.
if ! LLVM_PROFILE_FILE="$logs/list-%p.profraw" \
    swift test list -c debug > "$logs/list.txt" 2> "$logs/list.err"; then
  cat "$logs/list.err" >&2
  fail "swift test list failed"
  exit "$status"
fi

if [ ! -f "$logs/list.txt" ]; then
  fail "test listing output is missing"
  exit "$status"
fi
if ! grep -q . "$logs/list.txt"; then
  fail "test listing is empty"
  exit "$status"
fi
# swift test list emits ModuleSuite/testName entries. Anchor the suite name so
# similarly named suites and diagnostic lines cannot inflate its count.
total=$(grep -c . "$logs/list.txt" || true)
selected=$(grep -cE "(^|[./])$isolated/" "$logs/list.txt" || true)
remaining=$((total - selected))
ran_isolated=$(ran "$logs/isolated.log")
ran_parallel=$(ran "$logs/parallel.log")

echo "==> listed $total test identifiers; $selected match $isolated"
echo "==> isolated run reported ${ran_isolated:-no} tests; parallel run reported ${ran_parallel:-no} tests"

[ "$selected" -ge 1 ] || fail "'$isolated' matches no listed test; the isolated run would test nothing"
[ "$remaining" -ge 1 ] || fail "'$isolated' matches every listed test"
if [ -z "$ran_isolated" ]; then
  fail "isolated invocation produced no swift-testing summary"
fi
if [ -z "$ran_parallel" ]; then
  fail "parallel invocation produced no swift-testing summary"
fi

exit "$status"
