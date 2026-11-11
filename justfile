# hop: build, test and run a dev build next to the release one.
# Signs with your Apple Development identity when one is in the keychain and Local.xcconfig sets
# DEVELOPMENT_TEAM (Accessibility grants then survive rebuilds), else with "hop Local Signing"
# (just local-cert), else ad-hoc.
#
# The release hop comes from Homebrew (brew install --cask pseudobun/tap/hop): /Applications/hop.app,
# com.pseudobun.hop, CLI `hop`. `just dev` builds "hop Dev" (com.pseudobun.hop.dev, own data,
# grants and Keychain items, no updates, no login item) into ~/Applications, quits the release hop
# and starts the dev one; `just undev` goes back. `hop-dev` is the dev build's CLI.

dev_app := env("HOME") / "Applications/hop Dev.app"
dev_cli := "/opt/homebrew/bin/hop-dev"
release_id := "com.pseudobun.hop"

local_identity := "hop Local Signing"
signing := `security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && grep -qE "^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]" Local.xcconfig 2>/dev/null && echo signed || { security find-identity -p codesigning 2>/dev/null | grep -q "hop Local Signing" && echo local || echo adhoc; }`
adhoc_flags := if signing != "signed" { "CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=" } else { "" }
# VERSION (release-please keeps it) and the commit count, as in release builds
version_flags := "MARKETING_VERSION=" + `tr -d '[:space:]' < VERSION` + " CURRENT_PROJECT_VERSION=" + `git rev-list --count HEAD 2>/dev/null || echo 1`

default: build

# Debug build into ./build.noindex (.noindex keeps Spotlight from listing more hops)
build config="Debug":
    xcodebuild -project hop.xcodeproj -scheme hop -configuration {{config}} -derivedDataPath build.noindex \
      -destination "platform=macOS,arch=arm64" -quiet {{adhoc_flags}} {{version_flags}} \
      HOP_BUNDLE_ID=com.pseudobun.hop.dev "HOP_DISPLAY_NAME=hop Dev" build

test:
    scripts/build-local.sh test

# Benchmark an optimised Debug build (scripts/bench.sh): just bench · just bench 200 (soak, footprint)
bench *args:
    scripts/bench.sh {{args}}

# Build "hop Dev", quit the release hop and run the dev one instead
dev: (build "Release")
    scripts/verify-binary.sh build.noindex/Build/Products/Release/hop.app
    @# No Apple Development identity: re-sign with the local certificate so TCC grants survive rebuilds.
    @# No hardened runtime: its library validation refuses Sparkle signed without a Team ID.
    @if [ "{{signing}}" = local ]; then \
      app=build.noindex/Build/Products/Release/hop.app; ent=$(mktemp); \
      codesign -d --entitlements :- "$app" > "$ent" 2>/dev/null; \
      if ! codesign --force --deep --entitlements "$ent" -s "{{local_identity}}" "$app" 2>/dev/null; then \
        echo "signing with {{local_identity}} failed (keychain locked?); ad-hoc instead" >&2; \
        codesign --force --deep --entitlements "$ent" -s - "$app"; fi; \
      rm -f "$ent"; codesign -v "$app"; fi
    @just _quit
    rm -rf "{{dev_app}}"
    mkdir -p "$(dirname "{{dev_app}}")"
    cp -R build.noindex/Build/Products/Release/hop.app "{{dev_app}}"
    ln -sf "{{dev_app}}/Contents/MacOS/hop" "{{dev_cli}}"
    open "{{dev_app}}"
    @echo "running {{dev_app}} ({{signing}}, CLI: hop-dev); just undev goes back to the release hop"

# Quit the dev build and start the release hop again
undev:
    @just _quit
    open -b {{release_id}}

# The old name: builds and runs the dev build, never touches the release hop
install: dev

# Quits every hop.app (release and dev). hop restores the Caps Lock mapping before it exits;
# `open` fails (-600) while it is still going. CLI runs (/opt/homebrew/bin/hop …) don't match.
_quit:
    -pkill -f '\.app/Contents/MacOS/hop$'
    @for i in $(seq 1 50); do pgrep -f '\.app/Contents/MacOS/hop$' >/dev/null || break; sleep 0.1; done

# Self-signed code-signing certificate for machines without an Apple Development identity.
# Grants (Accessibility, Full Disk Access) then follow the certificate, not each build.
local-cert:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-identity -p codesigning | grep -q "{{local_identity}}"; then echo "already in keychain"; exit 0; fi
    d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
    printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN={{local_identity}}\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$d/c.cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/k.pem" -out "$d/c.pem" -days 3650 -config "$d/c.cnf" 2>/dev/null
    # macOS's /usr/bin/openssl is LibreSSL: its pkcs12 already uses the legacy algorithms and has no -legacy flag
    legacy=$(openssl version | grep -q LibreSSL || echo -legacy)
    openssl pkcs12 -export $legacy -inkey "$d/k.pem" -in "$d/c.pem" -out "$d/c.p12" -passout pass:hop
    security import "$d/c.p12" -k ~/Library/Keychains/login.keychain-db -P hop -T /usr/bin/codesign
    echo "created {{local_identity}}; run just dev, then grant hop Dev its permissions once"

# Remove the dev build (the release hop stays; brew uninstall --cask pseudobun/tap/hop removes it)
uninstall:
    @just _quit
    rm -rf "{{dev_app}}" "{{dev_cli}}"
    -open -b {{release_id}}

footprint:
    scripts/check-footprint.sh 30

# Release build signed with a Developer ID, zipped into build.noindex/release (CI also notarizes it)
release-zip identity="":
    scripts/release-build.sh "{{identity}}"

# Build and publish a version by hand (normally release-please does this when its PR merges)
release tag=("v" + `tr -d '[:space:]' < VERSION`):
    gh workflow run release.yml -f tag={{tag}}
    @echo "started; gh run watch to follow it"

# Follow hop's log
log:
    log stream --level info --predicate 'subsystem BEGINSWITH "com.pseudobun.hop"'

# Regenerate examples/ from the templates hop writes on first launch
examples: build
    build.noindex/Build/Products/Debug/hop.app/Contents/MacOS/hop config template > examples/config.json5
    build.noindex/Build/Products/Debug/hop.app/Contents/MacOS/hop snippets template > examples/snippets.json5
