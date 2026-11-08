# hop — build and install locally.
# Signs with your Apple Development identity when one is in the keychain and
# Local.xcconfig sets DEVELOPMENT_TEAM (Accessibility grants then survive rebuilds),
# otherwise ad-hoc. Bundle id and team: Local.xcconfig (see Local.xcconfig.example).

app_dir := "/Applications"
cli_link := "/opt/homebrew/bin/hop"

signing := `security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && grep -qE "^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]" Local.xcconfig 2>/dev/null && echo signed || echo adhoc`
adhoc_flags := if signing == "adhoc" { "CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=" } else { "" }

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
    -pkill -x hop
    @# hop restores the Caps Lock mapping before it exits; `open` fails (-600) while it is still going
    @for i in $(seq 1 50); do pgrep -x hop >/dev/null || break; sleep 0.1; done
    rm -rf "{{app_dir}}/hop.app"
    cp -R build/Build/Products/Release/hop.app "{{app_dir}}/hop.app"
    ln -sf "{{app_dir}}/hop.app/Contents/MacOS/hop" "{{cli_link}}"
    open "{{app_dir}}/hop.app"
    @echo "installed {{app_dir}}/hop.app ({{signing}}), CLI at {{cli_link}}"

uninstall:
    -pkill -x hop
    rm -rf "{{app_dir}}/hop.app" "{{cli_link}}"

footprint:
    scripts/check-footprint.sh 30

# Regenerate examples/ from the templates hop writes on first launch
examples: build
    build/Build/Products/Debug/hop.app/Contents/MacOS/hop config template > examples/config.json5
    build/Build/Products/Debug/hop.app/Contents/MacOS/hop snippets template > examples/snippets.json5
