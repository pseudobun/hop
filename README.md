<div align="center">

<h1>hop</h1>

A tiny native macOS launcher. Pure Swift + AppKit, no WebKit. ~3.5 MB binary, ~40 MB RAM, 0 % idle CPU. Dark, dense and quiet: Outfit for text, Geist Mono for values, colours from a small set of design tokens.

</div>

## Features

- App launcher on ⌘Space with frecency ranking (Raycast-compatible scorer)
  - reopening within `general.keepQueryFor` seconds (10) brings back the last search and row, selected so typing replaces it
  - → at the end of the query, Tab or ⌘K opens the selected result's actions (Tab still completes paths and enters sub-modes)
  - fallbacks under the results, and alone when nothing matches so ↵ runs the first: Ask ChatGPT (sends the query), Search Google, Search GitHub (`general.fallbacks`, also any URL with `{query}`)
- Inline answers, each a card you copy (↵), paste (⌘↵) or copy with its unit (⇧⌘C):
  - calculator and unit conversion (`734h to min`, `1 sq mile = km2`)
  - currencies: `100 usd to eur`, `€50 in gbp`, `1.5k rsd v eur` (open.er-api.com rates, fetched only after you type a currency, at most twice a day; `calculator.currency` is where amounts go without a target)
  - time zones: `time in tokyo`, `5pm london in ljubljana`, `14:00 cet to pst`, `3pm tokyo`
  - dates: `tomorrow`, `in 3 weeks`, `next friday`, `24.12. + 30 days`, `days until christmas`, `days since 1.1.2026`, `week number`, a few in Slovenian (`jutri`, `čez 2 dni`)
  - colours: `#7c5cff`, `rgb(…) to hsl` with a swatch; ⌘K copies HEX, RGB, HSL or a SwiftUI Color
  - Calculator History keeps what you copied or pasted (⌘E calculates it again)
- Uninstall app (with `~/Library` leftovers, `brew uninstall --cask` when it applies), Clear Downloads, Empty Trash
- Kill Process: search running processes, quit, force kill or kill as administrator
- Caps Lock as Hyper key (⌃⌥⌘⇧), optional tap-for-Escape
- Five gentle Caps Lock LED blinks on launch/restart (where macOS supports the LED override), without changing Caps Lock's typing state
- WireGuard: tunnels as pills under the search field with live status (green on, amber activating). Click one to toggle it, or ⌘J to select: ←→ / Tab move, ↵ or Space toggles, Esc back; ⇧⌘J disconnects all; "+N" opens the full list. All keys are in `wireguard.keys` (`direct: "alt+cmd"` adds ⌥⌘1…9), `wireguard.barTunnels` picks and orders the pills, `wireguard.bar: false` hides the bar. Activating one deactivates the others first (`wireguard.exclusive: false` allows several at once). Also connect, disconnect, disconnect all as commands (WireGuard.app tunnels)
- Notes on ⌥. : a keyboard-first floating window over a folder of Markdown files (an Obsidian vault works as is). Search titles and text, live Markdown styling, ⌘E preview with tables, tasks, `[[links]]`, back / forward, pinned notes on top, move to Trash, new notes saved straight into the vault
- Clipboard History on ⇧⌥C, centred like the launcher: text, images, links, colours and files you copied, list on the left and a preview on the right (rendered Markdown, code, colour swatch with HEX / RGB / HSL, images), source app and stats. ↵ pastes into the app you were in, ⌘↵ copies, ⇧⌘P pins, ⌃X deletes, ⌘K for the rest, ⌘P filters by type
- Snippets: type a keyword anywhere (`;mail`) and it becomes the snippet, or search them in hop. Raycast's placeholders (`{clipboard}`, `{date format="…" offset="+1d"}`, `{time}`, `{uuid}`, `{cursor}`, `{argument}`, `{snippet}`, `{calculator}`, `| trim | uppercase` …), checked against Raycast's own parser
- File search on Spotlight's index (always current, no index of hop's own to keep in memory): names first, then files whose text matches, ranked like the launcher with frecency and recency. "f " or "Search Files"; a query starting with `~/` or `/` browses folders, Tab completes. ↵ open, ⌘↵ Show in Finder, ⌘Y Quick Look, ⇧⌘C copy path, ⌥⌘C copy file, ⇧⌘T Terminal, ⌘⌫ Trash
- Shelves (like Dropover): shake the pointer while dragging, or hold ⇧, and a small floating shelf opens under it. Park files, links, images and text, then drag the whole stack (or single rows) out wherever you need them; dragged-out items leave the shelf, and an unpinned shelf closes when empty. Dropping onto the AirDrop zone of an empty shelf sends straight away. Several shelves at once, pin (⌘P), Quick Look (Space), copy (⌘C) or paths (⇧⌘C), Show in Finder (⌘↵), add from clipboard (⌘V), ⌫ removes, ⌥-click × clears. "New Shelf", "New Shelf from Clipboard" and "Reopen Shelf" in hop (or `shelf.hotkey`, `shelf.clipboardHotkey`, `shelf.reopenHotkey`); `hop shelf <paths>` from scripts. Drag detection uses no extra permission
- KeePassXC: several databases (⌘D to switch, or search all), paste or copy password / username / TOTP / URL, favicons, pins, folder filter. Stays unlocked until ⌘L or quit (`keepass.autoLock` locks on sleep, screen lock and inactivity)
- Bookmarks from the config: name, URL, aliases ("hass") and an icon (image file, SF Symbol or emoji); ↵ opens in the default browser
- Emoji picker: "Search Emoji" or type `:` (`:fire`). A grid by category with Recently and Frequently Used on top; ←→↑↓ move, ↵ pastes, ⌘C copies, ⇧⌘C copies the name, ⌥⌘C the code points. Searches CLDR names and keywords in English and Slovenian (`srce`, `pivo`), plus slang and intents (`wtf`, `lol`, `rip`, `ship it`); `emoji.skinTone` for people and hands, ⌘T on one picks another skin tone. Data: `scripts/gen-emoji.py`, narrowed to what this macOS draws
- Settings on ⌘, (in the launcher, "Settings" in root search, or the menu bar bunny): categories in a sidebar grouped like the config (hop, Keyboard, Tools, AI, Integrations, Advanced) with search, values on the right. Toggles, pickers, steppers and a hotkey recorder write straight into `config.json5`, one key at a time with its comments kept, and apply at once. Bookmarks, KeePassXC databases and `hotkeys` bindings are listed with a button to the file
- Permissions screen: every macOS permission hop needs, with the system prompts (opens on first launch)
- `hop` CLI for scripts and agents

Requires macOS 26 on Apple Silicon (Release builds are arm64 only).

## Install

A full commented config is in [`examples/config.json5`](examples/config.json5) (hop writes the same file to `~/.config/hop/config.json5` on first launch), snippets in [`examples/snippets.json5`](examples/snippets.json5). `hop config template` prints it.

```sh
just install   # Release build → /Applications/hop.app, CLI → /opt/homebrew/bin/hop
```

With an Apple Development identity in the keychain and a team in `Local.xcconfig` the build is signed, so the Accessibility grant survives updates. Otherwise it is ad-hoc signed (grants reset on every rebuild).

### Building your own copy

```sh
git clone <this repo> hop && cd hop
cp Local.xcconfig.example Local.xcconfig   # optional: your team id and bundle id
just install
```

`Local.xcconfig` is gitignored. It sets `DEVELOPMENT_TEAM` (your Apple Developer team id, for signed builds) and `HOP_BUNDLE_ID` (default `dev.hop.app`). The bundle id also names hop's data folder (`~/Library/Application Support/<bundle id>`), its Keychain items and its log subsystem, so keep it once you have data. Without the file hop builds ad-hoc as `dev.hop.app`.

On first launch hop writes a commented config to `~/.config/hop/config.json5`; nothing personal is preset (KeePassXC, SSH hosts and bookmarks start empty, notes point at `~/Notes`).

Free ⌘Space first: System Settings → Keyboard → Keyboard Shortcuts → Spotlight → uncheck "Show Spotlight search". Or set another `general.hotkey`.

## Config

`~/.config/hop/config.json5` (JSON5, comments allowed) is created on first launch and reloaded on save. `HOP_CONFIG` overrides the path. `hop config check` validates it. Settings (⌘,) edits the same file in place: a changed value is replaced where it stands, a missing key is added at the top of its section, comments and layout stay; a symlinked config is written through the link.

KeePassXC master password: never put it in the config. Choose `keepass.password`:

| value | where the password comes from |
|---|---|
| `keychain` | typed once in hop, kept in the login Keychain, released after Touch ID (once per hop launch) |
| `prompt` | typed every time the database unlocks |
| `command` | stdout of `keepass.passwordCommand`, e.g. `security find-generic-password -w -s hop-keepass` |
| `none` | database without a password (key file only) |

Notes are plain `.md` files in `notes.folder`; hop keeps no copy. ⌘N starts a note in `notes.newNoteFolder` from `notes.template` (`{{title}}`, `{{date}}`, `{{time}}`). It gets its file name from its title, or from its first line. With `notes.bumpUpdated`, saving an edit sets an existing `updated:` frontmatter date to today. If a file changed elsewhere while it had unsaved edits in hop, the other version is kept next to it as `<name> (conflict).md`.

Notes are keyboard-first; ⌘/ shows every shortcut. The right-hand “On this page” outline lists the current note's headings, with nested levels, click-to-jump and an animated indicator that follows scrolling or the editing caret. It works in both edit and preview modes, updates as you type, and hides for notes without headings or when the window is too narrow.

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

Clipboard history lives in `~/Library/Application Support/<bundle id>/Clipboard` (folder 0700, files 0600). Copies marked concealed or transient (KeePassXC, 1Password, hop's own password pastes) and copies from `clipboard.ignoreApps` are never recorded. Unpinned entries go after `clipboard.keepDays` or beyond `clipboard.maxItems`. Deleting everything takes ⌃⇧X twice.

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
hop notes list server --json   # title matches, then text matches
hop notes show "Home"
hop notes new "Call Alex" "about the flat"   # or pipe the text in
echo "- [ ] renew domain" | hop notes append TODOs
hop clip list ssh --json       # clipboard history; needs clipboard.cliAccess: true
hop clip copy 3                # put entry 3 back on the clipboard
hop files justfile --limit=5   # Spotlight, names (or --content)
hop snippets expand ";mt" --who=Alex    # a snippet with its placeholders filled in
hop hotkeys                    # hop's hotkeys, the hotkeys section, every bindable command
hop config path | check | show
hop convert 100 usd to eur     # units or currency
hop codes --latest             # newest one-time code from Messages (Full Disk Access)
hop events --days=3 --json     # Calendar; from the running hop when this terminal has no access
pbpaste | hop tr | pbcopy      # between translate.languages with OpenAI ("Set OpenAI API Key" in hop)
hop tr "see you tomorrow" --to=sl
hop ocr screenshot.png         # or no file: select an area on screen; --copy
hop emoji "povit srček"        # the picker's search
hop bookmarks open kvm
hop permissions --json
```

Destructive commands only describe what they would do unless `--yes` is passed.

## Development

```sh
just build        # Debug
just test         # Swift Testing, golden fixtures in hopTests/Fixtures
scripts/build-local.sh build && open ~/Applications/hop.app --args -DebugShowOnLaunch YES -DebugQuery saf -DebugSnapshotPath /tmp/hop.png
```
