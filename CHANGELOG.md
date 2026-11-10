# Changelog

All notable changes to hop. Versions follow [Semantic Versioning](https://semver.org); entries
come from [Conventional Commits](https://www.conventionalcommits.org) via release-please.

## [0.1.0-beta.2](https://github.com/pseudobun/hop/compare/v0.1.0-beta.1...v0.1.0-beta.2) (2026-11-10)


### Features

* **updates:** install updates with Sparkle, as paw does ([#3](https://github.com/pseudobun/hop/issues/3)) ([1d2b0e2](https://github.com/pseudobun/hop/commit/1d2b0e2f24637a8f835e7d6e3c52d38eca932fe6))

## [0.1.0-beta.1](https://github.com/pseudobun/hop/releases/tag/v0.1.0-beta.1) (2026-11-10)

First public beta.

### Added

- App launcher on ⌘Space with frecency ranking, fallbacks (ChatGPT, Google, GitHub or any URL)
  and an action panel on ⌘K
- Inline answers: calculator, units, currencies, time zones, dates and colours
- Clipboard history, snippets with Raycast-compatible placeholders, and keyword expansion
- Notes over a folder of Markdown files (an Obsidian vault works as is)
- File search on Spotlight's index, shelves for dragging files around, emoji picker
- KeePassXC, WireGuard, Calendar, one-time codes from Messages, OCR and translation
- Uninstall apps with their leftovers, kill processes, clear Downloads, empty the Trash
- Caps Lock as a hyper key, global hotkeys for any command or app
- A Settings window that edits the commented `config.json5` in place, `${NAME}` values from
  a `.env` beside it
- A `hop` CLI for scripts and agents
- Signed and notarized release builds, a Homebrew cask (`brew install --cask pseudobun/tap/hop`)
  and a daily check for new releases (`updates.check`, `hop update`)
