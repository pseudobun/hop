#!/usr/bin/env bash
# hop's benchmark: an optimised Debug build ("hop Dev" data) that times showing the launcher,
# typing, the clipboard, notes, Settings and emoji, then reports its memory footprint.
# Usage: scripts/bench.sh [soak rounds] [extra -Debug… flags]
#   scripts/bench.sh                 timings + footprint
#   scripts/bench.sh 200             + footprint before/after 200 rounds of every scenario
#   scripts/bench.sh 200 -DebugBenchmarkStay YES   stays up afterwards for `leaks <pid>`
# Every number is milliseconds of main-thread time unless it says MB.
set -euo pipefail
cd "$(dirname "$0")/.."
soak="${1:-0}"; shift || true
dd=build.noindex/bench
xcodebuild -project hop.xcodeproj -scheme hop -configuration Debug -derivedDataPath "$dd" \
  -destination "platform=macOS,arch=arm64" -quiet CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  SWIFT_OPTIMIZATION_LEVEL=-O HOP_BUNDLE_ID=com.pseudobun.hop.dev "HOP_DISPLAY_NAME=hop Dev" build 2>&1 \
  | grep -E ': error:' && exit 1 || true
app="$dd/Build/Products/Debug/hop.app"
# One ad-hoc signature over hop and Sparkle, so library validation loads it; keeps get-task-allow for leaks.
ent=$(mktemp); trap 'rm -f "$ent"' EXIT
codesign -d --entitlements :- "$app" > "$ent" 2>/dev/null
codesign --force --deep --entitlements "$ent" -s - "$app" 2>/dev/null
exec "$app/Contents/MacOS/hop" -DebugBenchmark YES -DebugNoFocus YES -DebugBenchmarkSoak "$soak" "$@"
