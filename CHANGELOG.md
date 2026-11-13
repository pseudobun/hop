# Changelog

All notable changes to hop. Versions follow [Semantic Versioning](https://semver.org); entries
come from [Conventional Commits](https://www.conventionalcommits.org) via release-please.

## [0.1.0](https://github.com/pseudobun/hop/compare/v0.1.0-beta.6...v0.1.0) (2026-11-13)


### Features

* add custom themes from json5 files ([#18](https://github.com/pseudobun/hop/issues/18)) ([95d36df](https://github.com/pseudobun/hop/commit/95d36df6080c7bf04b3932661b0013e6761156cd))
* **settings:** check field values as you type and refuse ones that are wrong ([#32](https://github.com/pseudobun/hop/issues/32)) ([b997fc7](https://github.com/pseudobun/hop/commit/b997fc7fe150f5b463a44707199f93f4a2d49310))
* **settings:** one Plugins group, verified checks and a sortable plugin list ([#36](https://github.com/pseudobun/hop/issues/36)) ([a9a4967](https://github.com/pseudobun/hop/commit/a9a496779f2cbfbe3c1ecd7d430f4de3790bb513))
* split hop into core and plugins, with installable plugins and SDKs ([#25](https://github.com/pseudobun/hop/issues/25)) ([d29d658](https://github.com/pseudobun/hop/commit/d29d658fd5f095b0721ecdcdfc3e9def4595d385))
* **ui:** add liquid glass design and a real entrance fade ([#52](https://github.com/pseudobun/hop/issues/52)) ([58cada4](https://github.com/pseudobun/hop/commit/58cada49e61eb47fd6d17ba824c8b472ed84c937))
* **ui:** animate wireguard switching and notes navigation ([#55](https://github.com/pseudobun/hop/issues/55)) ([1d7d04b](https://github.com/pseudobun/hop/commit/1d7d04b9a165b517edb12b0cdb75e1d21e48ee2f))
* **ui:** fade the launcher in and glide the selection between rows ([#42](https://github.com/pseudobun/hop/issues/42)) ([de8edbb](https://github.com/pseudobun/hop/commit/de8edbbfb7769f9e9103655663489d66b2bd851b))
* **ui:** make liquid glass more see-through and configurable ([#58](https://github.com/pseudobun/hop/issues/58)) ([1d133f5](https://github.com/pseudobun/hop/commit/1d133f5a02a12a7dc8c813a50693f5bd54a14337))
* **updates:** add a beta channel and release betas from a beta branch ([#20](https://github.com/pseudobun/hop/issues/20)) ([6a8e9fb](https://github.com/pseudobun/hop/commit/6a8e9fb8038feb4d800fd175a7eec823cece8eb8))
* **updates:** add Update hop and Update Channel commands to the launcher ([#30](https://github.com/pseudobun/hop/issues/30)) ([1c36a00](https://github.com/pseudobun/hop/commit/1c36a002e9dc3546f1d613e3fa50033fa38f2abe))


### Bug Fixes

* apply config changes live and bring settings to front ([#59](https://github.com/pseudobun/hop/issues/59)) ([569f8e5](https://github.com/pseudobun/hop/commit/569f8e567b2e45ab272cb0117b3c71464c0ac841))
* **cask:** name the conflicting cask with its tap ([#46](https://github.com/pseudobun/hop/issues/46)) ([18a4680](https://github.com/pseudobun/hop/commit/18a4680a067a8927aeb6baa272de7dc0a6adf558))
* **cask:** name the conflicting cask with its tap ([#47](https://github.com/pseudobun/hop/issues/47)) ([51a5ac0](https://github.com/pseudobun/hop/commit/51a5ac0910e9b51bd32a3fb0d7cc583e058eb3bd))
* **cask:** use the current depends_on macos syntax ([e4ca387](https://github.com/pseudobun/hop/commit/e4ca3876bebadaaf02dd671561f3fa6a6b76c620))
* **cask:** use the current depends_on macos syntax ([#28](https://github.com/pseudobun/hop/issues/28)) ([cd2bde2](https://github.com/pseudobun/hop/commit/cd2bde2cfaf89084b809a566bcbb79f851e27f4b))
* **login:** keep dev builds out of login items ([#39](https://github.com/pseudobun/hop/issues/39)) ([e9bc463](https://github.com/pseudobun/hop/commit/e9bc46394d47f364d22e27879eea07a0b18466c3))
* **settings:** offer only the beta channel until a stable version exists ([#22](https://github.com/pseudobun/hop/issues/22)) ([d56a5f6](https://github.com/pseudobun/hop/commit/d56a5f65a8af23d8b5f250bcf6e963e1353001be))
* **settings:** offer only the beta channel until a stable version exists ([#24](https://github.com/pseudobun/hop/issues/24)) ([26407e4](https://github.com/pseudobun/hop/commit/26407e41e3d1f78273ca90b7b20a64db8c093f92))
* **ui:** fade the launcher in instead of popping it up ([#49](https://github.com/pseudobun/hop/issues/49)) ([de18cff](https://github.com/pseudobun/hop/commit/de18cffb95de99c8db972395891d0afd0ed2696f))

## [0.1.0-beta.6](https://github.com/pseudobun/hop/compare/v0.1.0-beta.5...v0.1.0-beta.6) (2026-11-11)


### ⚠ BREAKING CHANGES

* remove rings from main (kept on the experimental branch) ([#14](https://github.com/pseudobun/hop/issues/14))

### Performance

* cut memory and main-thread work in the launcher, clipboard and background tasks ([#15](https://github.com/pseudobun/hop/issues/15)) ([5b6874a](https://github.com/pseudobun/hop/commit/5b6874a481c0164848b1c2f2152d1d0d5cdf6f1c))


### Refactoring

* remove rings from main (kept on the experimental branch) ([#14](https://github.com/pseudobun/hop/issues/14)) ([b46fab6](https://github.com/pseudobun/hop/commit/b46fab60ea1cf1c134267d6086b1e3742d03c00c))

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
