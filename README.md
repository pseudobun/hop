<div align="center">

<h1>hop</h1>

A tiny native macOS launcher. Pure Swift + AppKit, no WebKit. ~5.5 MB binary, ~40 MB RAM, 0 % idle CPU. Styled with the olympus dashboard design system (Outfit, Geist Mono, DS tokens).

</div>

## Features

- App launcher on ⌘Space with frecency ranking (Raycast-compatible scorer)
- Inline calculator and unit conversion in plain language: "5 km to mi", "how many cm is 5 ft", "1h 30min in min", "half an hour in s", "100 mbps to MB/s", "koliko minut je 2 uri". Leave the target out ("2 min =", "30c") for the usual counterpart unit, or type part of it ("to sec")
- Uninstall app (with `~/Library` leftovers, `brew uninstall --cask` when it applies), Clear Downloads, Empty Trash
- Kill Process: search running processes, quit, force kill or kill as administrator
- Caps Lock as Hyper key (⌃⌥⌘⇧), optional tap-for-Escape
- WireGuard: connect, disconnect, disconnect all (WireGuard.app tunnels)
- Notes on ⌥. : a keyboard-first floating window over a folder of Markdown files (an Obsidian vault works as is). Search titles and text, live Markdown styling, ⌘E preview, tasks, `[[links]]`, back / forward, pinned notes on top, move to Trash, new notes saved straight into the vault
- Clipboard History on ⇧⌥C, centred like the launcher: text, images, links, colours and files you copied, list on the left and a preview on the right (rendered Markdown, code, colour swatch with HEX / RGB / HSL, images), source app and stats. ↵ pastes into the app you were in, ⌘↵ copies, ⇧⌘P pins, ⌃X deletes, ⌘K for the rest, ⌘P filters by type
- Snippets: type a keyword anywhere (`;mail`) and it becomes the snippet, or search them in hop. Raycast's placeholders (`{clipboard}`, `{date format="…" offset="+1d"}`, `{time}`, `{uuid}`, `{cursor}`, `{argument}`, `{snippet}`, `{calculator}`, `| trim | uppercase` …), checked against Raycast's own parser
- File search on Spotlight's index (always current, no index of hop's own to keep in memory): names first, then files whose text matches, ranked like the launcher with frecency and recency. "f " or "Search Files"; a query starting with `~/` or `/` browses folders, Tab completes. ↵ open, ⌘↵ Show in Finder, ⌘Y Quick Look, ⇧⌘C copy path, ⌥⌘C copy file, ⇧⌘T Terminal, ⌘⌫ Trash
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
| ⌘P (or ⌘O) | search titles and text: title matches first, then notes whose text has every word (phrase and match count rank them). Matches are highlighted, the count shows per note, and opening one jumps to it; ⌘G / ⇧⌘G step through the rest. ↑ ↓ move, ↵ or Tab back to the note |
| search syntax | `"exact phrase"`, `-word` leaves notes out, `path:Infra` (or `in:`) limits to a folder, `#tag` / `tag:x` matches frontmatter `tags:` or inline tags (nested `#a/b` counts for `#a`) |
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

Clipboard history lives in `~/Library/Application Support/dev.hop.app/Clipboard` (folder 0700, files 0600). Copies marked concealed or transient (KeePassXC, 1Password, hop's own password pastes) and copies from `clipboard.ignoreApps` are never recorded. Unpinned entries go after `clipboard.keepDays` or beyond `clipboard.maxItems`. Deleting everything takes ⌃⇧X twice.

Every global hotkey is configurable: `general.hotkey` (⌘Space), `notes.hotkey` (⌥.), `clipboard.hotkey` (⇧⌥C), plus a `hotkeys` section that binds any command or app:

```json5
hotkeys: {
  "Empty Trash": "hyper+t",      // a command title (or its id, e.g. "system.emptyTrash")
  "Safari": "hyper+s",           // an app name (or "app:com.apple.Safari"); pressed again while in front, it hides
  "Clipboard History": "hyper+v",
},
```

`hop hotkeys` lists every command you can bind. Bindings show next to their command in the launcher; a binding that clashes with hop's own hotkeys, another app or macOS shows up under Setup.

Snippets live in `~/.config/hop/snippets.json5` (created on first launch, reloaded on save; `snippets.file` moves it):

```json5
[
  { name: "Email", keyword: ";mail", text: "you@example.com" },
  { name: "Meeting", keyword: ";mt", text: "Meeting with {argument name=\"who\"} on {date offset=\"+1d\"}, {cursor}" },
]
```

A keyword expands as soon as it is typed (`snippets.expand`, Accessibility); a keyword that starts with a letter only expands as a whole word unless `snippets.expandWithinWords`. Snippets with `{argument}` ask for the values in hop first. Not in password fields, nor in `snippets.disabledApps`. "Save as Snippet" (⌘S) in the clipboard history adds an entry.

## Permissions

Run **hop Permissions** (it opens by itself on first launch); ↵ shows each macOS prompt, **Grant All** asks for all of them.

| Feature | Permission |
|---|---|
| Hyper key, paste into apps (KeePassXC, clipboard history), snippet expansion | Accessibility |
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
hop clip list ssh --json       # clipboard history; needs clipboard.cliAccess: true
hop clip copy 3                # put entry 3 back on the clipboard
hop files justfile --limit=5   # Spotlight, names (or --content)
hop snippets expand ";mt" --who=Mojca   # a snippet with its placeholders filled in
hop hotkeys                    # hop's hotkeys, the hotkeys section, every bindable command
hop config path | check | show
```

Destructive commands only describe what they would do unless `--yes` is passed.

## Development

```sh
just build        # Debug
just test         # Swift Testing, golden fixtures from ~/repos/raycast-re
scripts/build-local.sh build && open ~/Applications/hop.app --args -DebugShowOnLaunch YES -DebugQuery saf -DebugSnapshotPath /tmp/hop.png
```
