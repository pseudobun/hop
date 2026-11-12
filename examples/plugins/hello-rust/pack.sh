#!/usr/bin/env bash
# Builds the plugin and packs <id>.hopplugin.zip: plugin.json5 + bin/. Attach the zip to a
# GitHub release and install it with: hop plugin install github.com/<owner>/<repo>
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release
id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' plugin.json5 | head -1)
stage=$(mktemp -d)
mkdir -p "$stage/$id/bin"
cp plugin.json5 "$stage/$id/"
cp target/release/hop-hello "$stage/$id/bin/hop-hello"
rm -f "$id.hopplugin.zip"
(cd "$stage" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$id" "$OLDPWD/$id.hopplugin.zip")
rm -rf "$stage"
echo "packed $id.hopplugin.zip"
