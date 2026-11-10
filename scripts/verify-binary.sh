#!/usr/bin/env bash
# Fails if the main binary exceeds 6 MB or anything but Sparkle links WebKit (Sparkle shows
# release notes in a web view; hop's own code stays without it).
# Usage: scripts/verify-binary.sh [path/to/hop.app]
set -euo pipefail

app="${1:-build.noindex/Build/Products/Release/hop.app}"
bin="$app/Contents/MacOS/hop"
limit=$((6 * 1024 * 1024))

size=$(stat -f %z "$bin")
echo "binary: $size bytes ($(( size / 1024 )) KB)"
[ "$size" -le "$limit" ] || { echo "FAIL: binary larger than 6 MB"; exit 1; }

while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'Mach-O' && otool -L "$f" | grep -qi webkit; then
    echo "FAIL: $f links WebKit"
    exit 1
  fi
done < <(find "$app" -type f -not -path "*/Frameworks/Sparkle.framework/*" -print0)
echo "ok: no WebKit outside Sparkle"
