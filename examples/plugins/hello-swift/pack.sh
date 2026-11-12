#!/usr/bin/env bash
# Builds the plugin and packs <id>.hopplugin.zip: plugin.json5 + bin/. Attach the zip to a
# GitHub release and install it with: hop plugin install github.com/<owner>/<repo>
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' plugin.json5 | head -1)
stage=$(mktemp -d)
mkdir -p "$stage/$id/bin"
cp plugin.json5 "$stage/$id/"
cp "$(swift build -c release --show-bin-path)/HelloSwift" "$stage/$id/bin/hello-swift"
rm -f "$id.hopplugin.zip"
(cd "$stage" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$id" "$OLDPWD/$id.hopplugin.zip")
rm -rf "$stage"
echo "packed $id.hopplugin.zip"
