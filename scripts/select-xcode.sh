#!/usr/bin/env bash
#
# select-xcode.sh — point xcode-select at the newest installed Xcode.
#
# Both CI workflows (quotabar-ci.yml, release.yml) call this instead of
# hard-coding Xcode_16.x.app paths joined with `||`: when the macos-15 image
# drops an old minor, a hard-coded list fails every run, whereas this picks
# whatever the image actually has. Candidates are ranked by each bundle's own
# CFBundleShortVersionString, not its directory name, because the image default
# is sometimes plain Xcode.app, which a name glob over Xcode_*.app never sees.
#
# Usage:
#   scripts/select-xcode.sh [MAJOR]
#
#   MAJOR  restrict to that major version (e.g. 16). Omit for the newest of all.
#
# Selection is exported as DEVELOPER_DIR through $GITHUB_ENV when running in
# Actions, so later steps use the same toolchain without sudo; outside Actions
# it only prints the path. An empty match fails with the cause rather than as a
# confusing xcode-select error that reads like a toolchain regression.

set -euo pipefail

major="${1:-}"
case "$major" in
  ""|[0-9]|[0-9][0-9]) ;;
  *) echo "::error::MAJOR must be an integer, got '$major'" >&2; exit 2 ;;
esac

shopt -s nullglob
best=""
while IFS=' ' read -r _ app; do
  best="$app"
done < <(
  for app in /Applications/Xcode.app /Applications/Xcode_*.app; do
    plist="$app/Contents/Info.plist"
    # PlistBuddy prints "Doesn't Exist" to stdout for a missing file.
    [ -f "$plist" ] || continue
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    [ -n "$version" ] || continue
    if [ -n "$major" ] && [ "${version%%.*}" != "$major" ]; then continue; fi
    printf '%s %s\n' "$version" "$app"
  done | sort -V
)

if [ -z "$best" ]; then
  echo "::error::No Xcode${major:+ $major.x} under /Applications with a readable version" >&2
  ls -d /Applications/Xcode* >&2 || true
  exit 1
fi

dev="$best/Contents/Developer"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"
fi
export DEVELOPER_DIR="$dev"
echo "Selected $best"
xcodebuild -version
swift --version
