<div align="center">

<h1>hop</h1>

A tiny native macOS launcher. Pure Swift + AppKit, no WebKit. ~3 MB binary, ~15 MB RAM, 0 % idle CPU. Styled with the olympus dashboard design system (Outfit, Geist Mono, DS tokens).

</div>

## Features

- App launcher on ⌘Space with frecency ranking (Raycast-compatible scorer)
- Inline calculator
- Uninstall app (with `~/Library` leftovers, `brew uninstall --cask` when it applies), Clear Downloads, Empty Trash
- Kill Process: search running processes, quit, force kill or kill as administrator
- Caps Lock as Hyper key (⌃⌥⌘⇧), optional tap-for-Escape
- WireGuard: connect, disconnect, disconnect all (WireGuard.app tunnels)
- KeePassXC: several databases (⌘D to switch, or search all), paste or copy password / username / TOTP / URL, favicons, pins, folder filter, auto-lock
- Permissions screen: every macOS permission hop needs, with the system prompts (opens on first launch)
- `hop` CLI for scripts and agents

Requires macOS 26.

## Install

```sh
just install   # Release build → /Applications/hop.app, CLI → /opt/homebrew/bin/hop
```

With an Apple Development identity in the keychain the build is signed, so the Accessibility grant survives updates. Otherwise it is ad-hoc signed (grants reset on every rebuild).

Free ⌘Space first: System Settings → Keyboard → Keyboard Shortcuts → Spotlight → uncheck "Show Spotlight search". Or set another `general.hotkey`.

## Config

`~/.config/hop/config.json5` (JSON5, comments allowed) is created on first launch and reloaded on save. `HOP_CONFIG` overrides the path. `hop config check` validates it.

KeePassXC master password: never put it in the config. Choose `keepass.password`:

| value | where the password comes from |
|---|---|
| `keychain` | typed once in hop, kept in the login Keychain, released after Touch ID |
| `prompt` | typed every time the database unlocks |
| `command` | stdout of `keepass.passwordCommand`, e.g. `security find-generic-password -w -s hop-keepass` |
| `none` | database without a password (key file only) |

## Permissions

Run **hop Permissions** (it opens by itself on first launch); ↵ shows each macOS prompt, **Grant All** asks for all of them.

| Feature | Permission |
|---|---|
| Hyper key, paste into apps | Accessibility |
| Empty Trash, removing protected apps | Automation → Finder |
| Clear Downloads | Downloads folder |
| KeePassXC (`keychain`) | Touch ID / login password |
| Open at Login (`general.openAtLogin`) | Login Items |

## CLI

```sh
hop apps saf --json
hop calc "200 + 10%"
hop uninstall Slack            # dry run, prints what would be removed (exit 3)
hop uninstall Slack --yes
hop downloads clear --yes
hop trash empty --yes
hop wg list | up <name> | down <name> | down-all
hop hyper status | map | unmap
hop ps code                    # processes, busiest first
hop kill 1234 --force --yes
hop kp dbs
hop kp search github --db Work --json
hop kp get github --field totp # password, totp and notes need keepass.cliAccess: true
hop config path | check | show
```

Destructive commands only describe what they would do unless `--yes` is passed.

## Development

```sh
just build        # Debug
just test         # Swift Testing, golden fixtures from ~/repos/raycast-re
scripts/build-local.sh build && open ~/Applications/hop.app --args -DebugShowOnLaunch YES -DebugQuery saf -DebugSnapshotPath /tmp/hop.png
```
