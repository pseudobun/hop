# hop — build and install locally.
# Signs with your Apple Development identity when one is in the keychain
# (Accessibility grants then survive rebuilds), otherwise ad-hoc.

app_dir := "/Applications"
cli_link := "/opt/homebrew/bin/hop"

signing := `security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && echo signed || echo adhoc`
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
