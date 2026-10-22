<div align="center">

<h1>hop</h1>

A tiny native macOS launcher. Pure Swift + AppKit, no WebKit.

</div>

## Features (v1)

- App launcher on ⌘Space with frecency ranking
- Inline calculator
- Uninstall app (with leftovers), Clear Downloads, Empty Trash
- Caps Lock as Hyper key (⌃⌥⌘⇧)
- WireGuard tunnels: connect, disconnect, disconnect all
- KeePassXC: search, paste/copy password, username, TOTP and URL

Requires macOS 26.

## Build

Open `hop.xcodeproj` in Xcode and run, or on a machine without a signing identity:

```sh
scripts/build-local.sh build   # ad-hoc build, installs to ~/Applications/hop.app
scripts/build-local.sh test
```

Free ⌘Space first: System Settings → Keyboard → Keyboard Shortcuts → Spotlight → uncheck "Show Spotlight search".
