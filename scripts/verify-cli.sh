#!/usr/bin/env bash
#
# verify-cli.sh — shared smoke test for the frugalbar CLI binaries.
#
# Both CI workflows (quotabar-ci.yml, release.yml) call this instead of
# duplicating their own watchdog logic, so a change to the binary's CLI output
# or to the hang handling lands in exactly one place. macOS runners ship no
# GNU `timeout`; perl's alarm() is the portable substitute, and its itimer
# survives exec() so a hung binary still gets killed.
#
# The script is deliberately *not* run with `set -e`: like release.yml's old
# inline check, it captures the watchdog child's exit status itself so it can
# tell a watchdog kill (142) from a normal crash and print a ::error:: line
# that names which happened, instead of aborting bare on perl's exit code.
#
# Exit codes / diagnostics:
#   * exit 0 when every check passes
#   * exit non-zero with a ::error:: line for any failure:
#       - the binary hung past the 10s watchdog (perl exits 142)
#       - the binary exited non-zero
#       - --version printed something other than --version-text
#       - --help did not contain a "Usage: <usage>" line
#       - required arguments are missing or the binary is not executable
#
# Usage:
#   scripts/verify-cli.sh --binary <path> --version-text "<expected>" --usage <name>
#
#   --binary        path to the executable to exercise (required)
#   --version-text  exact string `--version` must print (required)
#   --usage         program name that must appear in --help's "Usage:" line
#                   (required; matches basename(argv0), so it is QuotaBar on
#                   the CI debug build and frugalbar on the release binary)

set -u

binary=""
expected_version=""
usage_name=""

print_usage() {
	echo "usage: verify-cli.sh --binary <path> --version-text \"<expected>\" --usage <name>" >&2
}

# Value-taking option branches shift past their value, so a trailing flag with
# no value (e.g. a bare `--binary`) must be caught here rather than left to a
# failed `shift 2` — which in bash leaves the positional parameters unchanged
# and would re-parse the same flag forever (a hang in the script's own arg
# parser, the very failure mode the script exists to surface for the binary).
require_value() {
	local flag="${1:-}" value="${2:-}"
	if [ -z "$value" ]; then
		echo "::error::verify-cli.sh: $flag requires a value"
		print_usage
		exit 2
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
	--binary)
		require_value "$1" "${2:-}"
		binary="$2"
		shift 2
		;;
	--version-text)
		require_value "$1" "${2:-}"
		expected_version="$2"
		shift 2
		;;
	--usage)
		require_value "$1" "${2:-}"
		usage_name="$2"
		shift 2
		;;
	-h | --help)
		print_usage
		exit 0
		;;
	*)
		echo "::error::verify-cli.sh: unknown argument '$1'"
		print_usage
		exit 2
		;;
	esac
done

if [ -z "$binary" ] || [ -z "$expected_version" ] || [ -z "$usage_name" ]; then
	echo "::error::verify-cli.sh: --binary, --version-text and --usage are all required"
	print_usage
	exit 2
fi

if [ ! -x "$binary" ]; then
	echo "::error::verify-cli.sh: binary not executable: $binary"
	exit 2
fi

fail() {
	echo "::error::$*"
	exit 1
}

# Scratch file for the watchdog child's stdout. We write there (not to a
# command substitution) precisely so `fail` above runs at the top level of the
# script — inside `$(...)` an `exit 1` only kills the subshell and the error
# text would leak into "output" instead of aborting the step.
OUTFILE=$(mktemp)
trap 'rm -f "$OUTFILE"' EXIT

# check <label> <arg...>
# Runs `$binary <args...>` under a 10s perl watchdog, writing stdout to
# $OUTFILE. Aborts the script with a ::error:: line if the binary hung (perl
# exits 142) or exited non-zero; otherwise returns 0 with the output in
# $OUTFILE.
check() {
	local label="$1"
	shift
	perl -e 'alarm 10; exec @ARGV or die "exec failed: $!"' "$binary" "$@" >"$OUTFILE" 2>&1
	local status=$?
	if [ "$status" -eq 142 ]; then
		fail "$binary $* did not exit within the 10s watchdog (${label} hung)"
	elif [ "$status" -ne 0 ]; then
		fail "$binary $* exited with status $status"
	fi
}

check version --version
VERSION_OUTPUT=$(cat "$OUTFILE")
[ "$VERSION_OUTPUT" = "$expected_version" ] || {
	fail "$binary --version printed '$VERSION_OUTPUT', expected '$expected_version'"
}

check help --help
HELP_OUTPUT=$(cat "$OUTFILE")
if ! grep -q "Usage: ${usage_name}" <<<"$HELP_OUTPUT"; then
	fail "$binary --help output did not contain a 'Usage: ${usage_name}' line"
fi

echo "OK: $binary --version => '$expected_version'; --help usage line names '$usage_name'"
