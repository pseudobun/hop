# hop — build and install locally.
# Signs with your Apple Development identity when one is in the keychain and
# Local.xcconfig sets DEVELOPMENT_TEAM (Accessibility grants then survive rebuilds),
# otherwise ad-hoc. Bundle id and team: Local.xcconfig (see Local.xcconfig.example).

app_dir := "/Applications"
cli_link := "/opt/homebrew/bin/hop"

local_identity := "hop Local Signing"
signing := `security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && grep -qE "^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]" Local.xcconfig 2>/dev/null && echo signed || { security find-identity -p codesigning 2>/dev/null | grep -q "hop Local Signing" && echo local || echo adhoc; }`
adhoc_flags := if signing != "signed" { "CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=" } else { "" }

default: build

# Debug build into ./build
build config="Debug":
    xcodebuild -project hop.xcodeproj -scheme hop -configuration {{config}} -derivedDataPath build \
      -destination "platform=macOS,arch=arm64" -quiet {{adhoc_flags}} build

test:
    scripts/build-local.sh test

# Release build, copied to /Applications, CLI linked into PATH, relaunched
install: (build "Release")
    scripts/verify-binary.sh build/Build/Products/Release/hop.app
    @# No Apple Development identity: re-sign with the local certificate so TCC grants survive rebuilds
    @if [ "{{signing}}" = local ]; then \
      app=build/Build/Products/Release/hop.app; ent=$(mktemp); \
      codesign -d --entitlements :- "$app" > "$ent" 2>/dev/null; \
      if ! codesign --force --deep --options runtime --entitlements "$ent" -s "{{local_identity}}" "$app" 2>/dev/null; then \
        echo "signing with {{local_identity}} failed (keychain locked?); ad-hoc instead" >&2; \
        codesign --force --deep --entitlements "$ent" -s - "$app"; fi; \
      rm -f "$ent"; codesign -v "$app"; fi
    -pkill -x hop
    @# hop restores the Caps Lock mapping before it exits; `open` fails (-600) while it is still going
    @for i in $(seq 1 50); do pgrep -x hop >/dev/null || break; sleep 0.1; done
    rm -rf "{{app_dir}}/hop.app"
    cp -R build/Build/Products/Release/hop.app "{{app_dir}}/hop.app"
    ln -sf "{{app_dir}}/hop.app/Contents/MacOS/hop" "{{cli_link}}"
    open "{{app_dir}}/hop.app"
    @echo "installed {{app_dir}}/hop.app ({{signing}}), CLI at {{cli_link}}"

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
    echo "created {{local_identity}}; run just install, then re-grant permissions once"

uninstall:
    -pkill -x hop
    rm -rf "{{app_dir}}/hop.app" "{{cli_link}}"

footprint:
    scripts/check-footprint.sh 30

# Regenerate examples/ from the templates hop writes on first launch
examples: build
    build/Build/Products/Debug/hop.app/Contents/MacOS/hop config template > examples/config.json5
    build/Build/Products/Debug/hop.app/Contents/MacOS/hop snippets template > examples/snippets.json5
