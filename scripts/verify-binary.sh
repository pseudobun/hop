#!/usr/bin/env bash
# Fails if any Mach-O in the app links WebKit or the main binary exceeds 5 MB.
# Usage: scripts/verify-binary.sh [path/to/hop.app]
set -euo pipefail

app="${1:-build/Build/Products/Release/hop.app}"
bin="$app/Contents/MacOS/hop"
limit=$((5 * 1024 * 1024))

size=$(stat -f %z "$bin")
echo "binary: $size bytes ($(( size / 1024 )) KB)"
[ "$size" -le "$limit" ] || { echo "FAIL: binary larger than 5 MB"; exit 1; }

while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'Mach-O' && otool -L "$f" | grep -qi webkit; then
    echo "FAIL: $f links WebKit"
    exit 1
  fi
done < <(find "$app" -type f -print0)
echo "ok: no WebKit"
