# Changelog

All notable changes to hop. Versions follow [Semantic Versioning](https://semver.org); entries
come from [Conventional Commits](https://www.conventionalcommits.org) via release-please.

## [0.1.0-beta.5](https://github.com/pseudobun/hop/compare/v0.1.0-beta.4...v0.1.0-beta.5) (2026-11-11)


### Features

* **rings:** add radial gesture menus with built-in actions and app rings ([512c332](https://github.com/pseudobun/hop/commit/512c3320bad3310713edeef3db1b1cc5abc82de7))


### Bug Fixes

* **rings:** build on the CI toolchain and allow preset keystrokes in gitleaks ([49b5ba0](https://github.com/pseudobun/hop/commit/49b5ba097ed84ca79b72703b68a4bbfa0ddcacff))
* **security:** authenticate the CLI channel and gate code-running ring actions ([08ec786](https://github.com/pseudobun/hop/commit/08ec78644f5aa811ac343be8611a3fcd42fd2bd7))

## [0.1.0-beta.4](https://github.com/pseudobun/hop/compare/v0.1.0-beta.3...v0.1.0-beta.4) (2026-11-10)


### Features

* **dev:** build from source as hop Dev, next to the release hop ([#8](https://github.com/pseudobun/hop/issues/8)) ([a3f0603](https://github.com/pseudobun/hop/commit/a3f060386d755985fc75c0e1591ec1d7856ea047))

## [0.1.0-beta.3](https://github.com/pseudobun/hop/compare/v0.1.0-beta.2...v0.1.0-beta.3) (2026-11-10)


### Features

* **updates:** update silently and offer hop's and paw's updates in the launcher ([#5](https://github.com/pseudobun/hop/issues/5)) ([ad710a7](https://github.com/pseudobun/hop/commit/ad710a7129f66c05813595ebb3eab5b930f1a5fd))

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
