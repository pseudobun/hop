#!/usr/bin/env bash
# Ad-hoc build for machines without a signing identity.
# Usage: scripts/build-local.sh [build|test] [Debug|Release]
set -euo pipefail

cd "$(dirname "$0")/.."
action="${1:-build}"
config="${2:-Debug}"

args=(
  -project hop.xcodeproj
  -scheme hop
  -configuration "$config"
  -derivedDataPath build.noindex
  -destination "platform=macOS,arch=arm64"
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=
)

if [ "$action" = "test" ]; then
  set +e
  xcodebuild "${args[@]}" test 2>&1 \
    | grep -E 'error:|✘|✔ Test run|recorded an issue|TEST (SUCCEEDED|FAILED)'
  exit "${PIPESTATUS[0]}"
fi

xcodebuild "${args[@]}" -quiet build
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/hop.app"
cp -R "build.noindex/Build/Products/$config/hop.app" "$HOME/Applications/hop.app"
echo "installed: $HOME/Applications/hop.app"
