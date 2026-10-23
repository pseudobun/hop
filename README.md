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
- Notes on ⌥. : a keyboard-first floating window over a folder of Markdown files (an Obsidian vault works as is). Search titles and text, live Markdown styling, ⌘E preview, tasks, `[[links]]`, back / forward, pinned notes on top, move to Trash, new notes saved straight into the vault
- KeePassXC: several databases (⌘D to switch, or search all), paste or copy password / username / TOTP / URL, favicons, pins, folder filter. Stays unlocked until ⌘L or quit (`keepass.autoLock` locks on sleep, screen lock and inactivity)
- Bookmarks from the config: name, URL, aliases ("hass") and an icon (image file, SF Symbol or emoji); ↵ opens in the default browser
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
| `keychain` | typed once in hop, kept in the login Keychain, released after Touch ID (once per hop launch) |
| `prompt` | typed every time the database unlocks |
| `command` | stdout of `keepass.passwordCommand`, e.g. `security find-generic-password -w -s hop-keepass` |
| `none` | database without a password (key file only) |

Notes are plain `.md` files in `notes.folder`; hop keeps no copy. ⌘N starts a note in `notes.newNoteFolder` from `notes.template` (`{{title}}`, `{{date}}`, `{{time}}`). It gets its file name from its title, or from its first line. With `notes.bumpUpdated`, saving an edit sets an existing `updated:` frontmatter date to today. If a file changed elsewhere while it had unsaved edits in hop, the other version is kept next to it as `<name> (conflict).md`.

Notes are keyboard-first; ⌘/ shows every shortcut.

| Notes key | |
|---|---|
| ⌥. | show / hide (from anywhere) |
| ⌘P (or ⌘O) | search notes: typing previews the first match, ↑ ↓ move, ↵ or Tab back to the note |
| ⇧↵ in search | new note named after the search (also ↵ when nothing matches) |
| ⌥⌘↑ / ⌥⌘↓ | previous / next note in the list |
| ⌘[ / ⌘] | back / forward |
| ⌥↵ or ⌘↵ | follow the link at the caret (⌘-click, or a plain click in preview); a missing `[[page]]` starts a new note |
| ⌘E | edit ⇄ preview (rendered, read-only; click a task box to tick it; ↑ ↓ Space scroll) |
| ⌘F, ⌘G, ⇧⌘G | find in the note |
| ⌘N | new note |
| ⌘K | actions, like the launcher: open / preview, pin (⌘D), Obsidian (⇧⌘O), Show in Finder, copy `[[link]]` (⇧⌘C), Markdown (⌥⌘C) or path, Trash (⇧⌘⌫). Acts on the note under the mouse in the list, else the open one; right-click a row for the same list |
| ⌘L / ⌘B / ⌘I | toggle task / bold / italic |
| ⌘\\ | hide the sidebar |
| ⌘D | pin / unpin; pinned notes stay at the top of the list |
| ⇧⌘⌫ | move the note to the Trash (also on right-click in the list) |
| ⇧⌘O | open in Obsidian |
| Esc | close find, then search, then the window (it floats above other apps until then) |

## Permissions

Run **hop Permissions** (it opens by itself on first launch); ↵ shows each macOS prompt, **Grant All** asks for all of them.

| Feature | Permission |
|---|---|
| Hyper key, paste into apps | Accessibility |
| Empty Trash, removing protected apps | Automation → Finder |
| Clear Downloads | Downloads folder |
| Notes in iCloud Drive | iCloud Drive access, if macOS asks |
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
hop notes list olympus --json  # title matches, then text matches
hop notes show "Home"
hop notes new "Call Mojca" "about the flat"   # or pipe the text in
echo "- [ ] renew domain" | hop notes append TODOs
hop config path | check | show
```

Destructive commands only describe what they would do unless `--yes` is passed.

## Development

```sh
just build        # Debug
just test         # Swift Testing, golden fixtures from ~/repos/raycast-re
scripts/build-local.sh build && open ~/Applications/hop.app --args -DebugShowOnLaunch YES -DebugQuery saf -DebugSnapshotPath /tmp/hop.png
```
