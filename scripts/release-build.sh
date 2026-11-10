#!/usr/bin/env bash
# Release hop.app: arm64 Release build signed with a Developer ID (hardened runtime, secure
# timestamp) and zipped. CI notarizes, staples and publishes it.
# Usage: scripts/release-build.sh [identity]
# Env:   HOP_SIGN_IDENTITY (or the argument; empty signs ad-hoc for a dry run),
#        HOP_VERSION (default: VERSION), HOP_BUILD (CFBundleVersion;
#        default: commit count), HOP_UPDATE_FEED (Sparkle appcast; default: the appcast branch
#        of pseudobun/hop), HOP_SPARKLE_PUBLIC_KEY (EdDSA key that signs updates; private half:
#        the SPARKLE_PRIVATE_KEY secret and olympus' keychain, account hop),
#        HOP_OUT (default: build.noindex/release)
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${1:-${HOP_SIGN_IDENTITY:-}}"
version="${HOP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
build="${HOP_BUILD:-$(git rev-list --count HEAD)}"
feed="${HOP_UPDATE_FEED-https://raw.githubusercontent.com/pseudobun/hop/appcast/appcast.xml}"
sparkle_key="${HOP_SPARKLE_PUBLIC_KEY-9SltzAFVk2+DCMfPJgKtwv1Vyq+SzTcc4qEURxWq5+c=}"
out="${HOP_OUT:-build.noindex/release}"
derived=build.noindex/release-derived

# Release identity on the command line, so a Local.xcconfig of your own doesn't change it.
xcodebuild -project hop.xcodeproj -scheme hop -configuration Release -derivedDataPath "$derived" \
  -destination "platform=macOS,arch=arm64" -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  HOP_BUNDLE_ID=com.pseudobun.hop "HOP_COPYRIGHT=© 2026 hop contributors" \
  HOP_UPDATE_FEED="$feed" HOP_SPARKLE_PUBLIC_KEY="$sparkle_key" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" build

rm -rf "$out"; mkdir -p "$out"
app="$out/hop.app"
ditto "$derived/Build/Products/Release/hop.app" "$app"
scripts/verify-binary.sh "$app"

# hop isn't sandboxed, so Sparkle needs no XPC services.
fw="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$fw/Versions/B/XPCServices" "$fw/XPCServices"

# Inside out: Sparkle's helpers, the framework, then the app. Hardened runtime (needed for
# notarization) only with an identity: its library validation refuses the ad-hoc framework.
if [ -n "$identity" ]; then sign_flags=(--force --options runtime --timestamp -s "$identity"); else sign_flags=(--force -s -); fi
codesign "${sign_flags[@]}" "$fw/Versions/B/Autoupdate"
codesign "${sign_flags[@]}" "$fw/Versions/B/Updater.app"
codesign "${sign_flags[@]}" "$fw"
codesign "${sign_flags[@]}" --entitlements hop/Support/hop.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

zip="$out/hop-$version-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "built $app ($version, build $build) and $zip"
