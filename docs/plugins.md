# hop plugins

Everything hop does beyond core is done by a plugin: the clipboard, notes, KeePassXC, the
calculator and the rest. There are two kinds.

| | Built-in plugins | Installed plugins |
|---|---|---|
| Where | this repository, `hop/Plugins/<Name>/` | a GitHub release (`*.hopplugin.zip`) |
| Language | Swift, compiled into hop | anything: Swift and Rust have SDKs |
| Runs | inside hop | as its own program, started on demand |
| UI | any AppKit, own windows | lists and grids hop draws |
| Settings | a page the plugin describes | a page from `plugin.json5` |
| CLI | `hop <name> …` in Swift | `hop <name> …` answered by the program |
| Review | pull request (Verified) | none (Community) |

Core is what is left: the launcher, root search, apps, fallbacks, themes, hotkeys, Settings,
permissions, updates, IPC, and the `hop` commands that are about hop itself (`apps`, `open`,
`config`, `hotkeys`, `permissions`, `plugin`, `version`, `update`). Every other `hop` command
belongs to a plugin.

The Plugins page in Settings (or **Open Plugins** in the launcher) lists every plugin with its
switch, its settings and an **Install from GitHub** field.

## Config

A built-in plugin keeps its own top-level section, as before:

```json5
notes: { enabled: true, folder: "~/Notes" },
```

Plugins without an `enabled` key of their own (Calculator, Bookmarks, System, paw and every
installed plugin) are turned off in `plugins.disabled`. Installed plugins keep their settings
under their id:

```json5
plugins: {
  disabled: ["paw"],
  "dev.you.github": { org: "lutralabs" },
},
```

Changes in the file or in Settings apply at once. A preference of type `secret` never touches the
config: Settings saves it in the login Keychain, and hop hands it to the plugin at start.

`plugins.install` makes the config the list of installed plugins, so a dotfiles repo (or an agent)
can declare them:

```json5
plugins: {
  install: ["you/hop-github", "someone/hop-thing@v1.2.0", "~/src/x/dev.me.x.hopplugin.zip"],
},
```

hop installs what the list names and removes installed plugins it no longer names, at launch and
whenever the list changes (`hop plugin sync` does the same from a shell, `--yes` to apply). Without
the key, installed plugins are left alone. Installing from Settings or `hop plugin install` adds
the entry; removing deletes it. Anything that can write the config can therefore install code,
like `keepass.passwordCommand` already runs it: review config changes like code.

### For scripts and agents

Everything Settings does has a command, and every command only edits `config.json5` (comments
kept), so the file stays the one source of truth:

```sh
hop plugin list --json                  # id, name, tier, on/off, source, its commands, pending sync
hop plugin enable keepass               # or disable
hop plugin settings keepass --json      # every key: type, default, current value, hidden or not
hop plugin set notes folder "~/Vault"   # one key (installed plugins: their preference ids)
hop plugin set dev.you.github token -   # a secret, read from stdin into the Keychain
hop config show                         # the whole effective config as JSON
hop config get plugins.disabled
hop config set general.hotkey '"alt+space"'   # refused, and nothing written, if the config would not read
```

## Built-in plugins

A built-in plugin is a folder in `hop/Plugins/` with a class that adopts `BuiltinPlugin`
(`hop/Core/Plugins/HopPlugin.swift`) and its tests in `hopTests/Plugins/`. Register it once in
`hop/Plugins/BuiltinPlugins.swift`.

```swift
final class WeatherPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "weather", name: "Weather", summary: "Forecast in root search.", symbol: "cloud.sun.fill",
                   color: Theme.chart1, category: .integrations, enabledPath: ["weather", "enabled"])
    }

    static var settings: [SettingsSection] {
        [SettingsSection([
            .setting("weather.enabled", "Weather", .toggle),
            .setting("weather.city", "City", .text(placeholder: "Ljubljana")),
            .setting("weather.apiURL", "API", .text(), hidden: true),   // only in the config file
        ])]
    }

    init() {}
    private weak var host: PluginHost?
    func start(_ host: PluginHost) { self.host = host }
    func commands() -> [Item] { … }
}
```

Its config section is a `PluginConfig` in the same folder (`WeatherConfig.swift`), with an accessor
on `HopConfig` so code reads `config.weather.city`:

```swift
nonisolated extension HopConfig {
    nonisolated struct Weather: PluginConfig {
        static let key = "weather"
        var enabled = true
        var city = ""
    }

    var weather: Weather {
        get { sections[Weather.self] }
        set { sections[Weather.self] = newValue }
    }
}
```

Every hook has a default, so a plugin implements only what it uses:

| Hook | For |
|---|---|
| `start(host)` | once at launch: keep `host`, build controllers |
| `apply(config, previous, enabled)` | every config change, on or off |
| `commands()` | root search items |
| `prefixModes()` | `"kp "` → a mode |
| `hotkeys(config)` | global hotkeys hop registers and checks for clashes |
| `bindings()` | names the `hotkeys` section can bind ("new note") |
| `answer(for:isAmbiguous:)` | an inline answer above the results |
| `upcomingItems()` | the root's Upcoming section |
| `pathMode()` | what `~/…` opens |
| `appActions(entry)` | extra actions on an app row |
| `static cli` | `hop <name> …` commands (they run in the CLI process, without the app) |
| `launcherWillShow()`, `setAway(_:)`, `themeDidChange(saved:)`, `stop()` | lifecycle |

`PluginHost` gives a plugin the services, settings, launcher and other plugins
(`host.plugin(ClipboardPlugin.self)`).

CLI commands sit next to the plugin (`NotesCommandLine.swift`):

```swift
extension WeatherPlugin {
    static var cli: [CLICommand] {
        [CLICommand(names: ["weather"], usage: ["weather [city] [--json]   Today's forecast"], run: CLI.weather)]
    }
}
```

## Installed plugins

### The package

A release asset named `*.hopplugin.zip` (an `arm64` or `universal` one first when there are
several) holds a folder, or the archive root, with:

```
plugin.json5
bin/your-program
icon.png            (optional, any files the plugin reads)
```

Symbolic links are refused. `hop plugin install ./x.hopplugin.zip` installs a local build.

### plugin.json5

```json5
{
  id: "dev.you.github",            // reverse DNS, lower case, unique
  name: "GitHub",
  version: "0.3.0",
  summary: "Your pull requests and issues.",
  author: "you",
  hop: "0.2.0",                    // lowest hop version
  entry: "bin/hop-github",         // the program, inside the folder
  symbol: "arrow.triangle.pull",   // SF Symbol for its tile
  color: "#7c5cff",
  commands: [
    // view (default): opens a list or grid the plugin fills
    { id: "prs", title: "My Pull Requests", keywords: ["pr"], prefix: "pr " },
    // instant: runs and answers with a HUD
    { id: "copy-token", title: "Copy Token", kind: "instant" },
    // background: runs every interval ("30s", "15m", "1h"; at least 10 s)
    { id: "sync", title: "Sync", kind: "background", interval: "15m" },
  ],
  preferences: [
    // text, secret, toggle, number, choice, list, textarea, hotkey
    { id: "token", title: "Token", type: "secret", required: true },
    { id: "org", title: "Organization", type: "text", placeholder: "lutralabs" },
    { id: "max", title: "At most", type: "number", default: 50, min: 1, max: 500, hidden: true },
    { id: "state", title: "Show", type: "choice", options: ["open", "all"], default: "open" },
  ],
  // Shown before install. hop does not enforce it.
  permissions: { network: ["api.github.com"], clipboard: "write", files: [], exec: [] },
  // `hop gh …` sends `cli` to the program and prints what it answers.
  cli: { name: "gh", usage: ["gh prs [--json]   Your open pull requests"] },
  // Every root-search query goes to `answer`; what comes back shows above the results.
  answers: true,
  // Extra actions on application rows; they arrive as `action` with command "app".
  appActions: [{ id: "open-repo", title: "Open Repository", symbol: "arrow.triangle.branch" }],
}
```

### The protocol

hop starts `entry` when a command first needs it, with the plugin folder as the working
directory and a small environment (`HOME`, `PATH`, `HOP_PLUGIN_ID`, `HOP_PLUGIN_DIR`,
`HOP_VERSION`). It stops it after a minute without requests and no open view, on sleep and screen
lock, when the plugin is turned off and when hop quits. Whatever the program writes to stderr goes
to hop's log (`log stream --predicate 'subsystem BEGINSWITH "com.pseudobun.hop" AND category == "plugin"'`).

Messages are [JSON-RPC 2.0](https://www.jsonrpc.org/specification), one per line, on stdin and
stdout.

| hop → plugin | Params | Reply |
|---|---|---|
| `initialize` | `protocolVersion`, `hopVersion`, `pluginID`, `preferences`, `dataDir`, `appearance` | anything |
| `run` | `command`, `query?` (text after its prefix), `background?` | a Response |
| `query` | `command`, `text` (views with `filtering: "plugin"`) | a Response |
| `action` | `command`, `id`, `payload` (a `callback` action; `command` is "root", "answer" or "app" for those items) | a Response |
| `submit` | `command`, `text` (↵ in a view with `submit: true`) | a Response |
| `answer` | `text` (a root query, with `answers: true`) | `{title?, items}` or null |
| `cli` | `args` (words after the name), `stdin?` | `{stdout?, stderr?, exitCode?}` |
| `shutdown` | (notification) | exit |

| plugin → hop (notifications) | Params |
|---|---|
| `render` | a Response with `view`, and `command` to pick the open view |
| `hud` | `text`, `style?` |
| `loading` | `loading: true/false` |
| `rootItems` | `items` (extra root commands), `upcoming` (the root's Upcoming section) |

An error reply (`{"error": {"code": -32000, "message": "…"}}`) shows as a red HUD. Requests time
out after 15 seconds.

A **Response** has any of: `view` (show or replace), `push` (open on top), `pop: true`, `hud`
(`{text, style: info|success|warn|fail}`), `dismiss: true` (hide the launcher).

A **View** is `{type: "list"|"grid", title?, placeholder?, filtering: "hop"|"plugin", columns?,
sections: [{title?, items}], items? (shorthand for one section), emptyText?, loading?, submit?,
secureInput?}`. `submit: true` makes ↵ with nothing selected send the typed text (`submit`), for
prompts like Translate's; `secureInput` hides it (a password). With
`filtering: "hop"` hop ranks the items as you type, like everywhere else; with `"plugin"` it sends
`query` once typing pauses.

An **Item** is `{id, title, subtitle?, icon?, accessory?, keywords?, chip?, actions}`; a chip is
`{text, tone: neutral|good|warn|bad|info}`. An icon is
`{symbol, color?}` (SF Symbol on a tile), `{emoji}` or `{file}`. `actions[0]` runs on ↵, the rest
are in ⌘K.

An **Action** is `{title, type, shortcut?, destructive?, confirm?}` plus what its type needs;
`confirm: {message, title?, button?}` shows a confirm screen first:

| type | needs | hop |
|---|---|---|
| `copy` | `value` | copies it, hides |
| `paste` | `value` | pastes into the app behind hop |
| `open` | `url` | opens it |
| `openFile` / `reveal` | `path` | opens it / shows it in Finder |
| `push` | `view` | opens it on top |
| `callback` | `id`, `payload?` | sends `action`, acts on the Response |

Shortcuts read like hotkeys: `"cmd+c"`, `"cmd+shift+return"`, `"ctrl+delete"`.

### SDKs

- **Rust**: `sdk/rust/hop-plugin` (`serde` only, no async runtime). Example:
  `examples/plugins/hello-rust`.
- **Swift**: `sdk/swift` (`HopPluginKit`, Swift Package). Example: `examples/plugins/hello-swift`.

Both give typed views, builders and `serve(plugin)`, which runs the loop. Each example has a
`pack.sh` that builds the program and writes `<id>.hopplugin.zip`:

```sh
cd examples/plugins/hello-rust && ./pack.sh
hop plugin install dev.hop.hello-rust.hopplugin.zip --yes
```

Any other language works: read lines, write lines.

### What an installed plugin can and cannot do

It has what built-in plugins use in the launcher: commands, prefixes, lists and grids, pushed
views, prompts (`submit`, `secureInput`), confirm screens, inline answers, root and Upcoming
items, app-row actions, background jobs, HUDs, settings of every type (secrets in the Keychain),
`hotkeys` bindings by command title, and `hop` CLI commands.

It cannot draw its own windows or views (Notes, Clipboard and Shelf are AppKit panels), tap the
keyboard (Hyper key, snippet expansion), add a strip under the search field (the WireGuard bar),
complete with Tab, or run inside hop. Those need a built-in plugin: open a pull request.

### Installing

From Settings → Plugins → Install from GitHub, or:

```sh
hop plugin install github.com/you/hop-github          # latest release
hop plugin install you/hop-github@v0.3.0 --yes
hop plugin list
hop plugin remove dev.you.github --yes
```

The CLI prints what the plugin declares and installs only with `--yes`; Settings asks the same in a
dialog. A running hop picks up the change at once.

## Trust

- **Verified**: the built-in plugins, reviewed in pull requests here, run inside hop.
- **Community**: installed from a GitHub link. hop shows where it comes from and what it says it
  uses, and asks before installing (except from `plugins.install`, where the config is the yes).

An installed plugin runs as you, with your access to files and the network, like any program you
download. hop spawns it as its own *responsible process*, so it does **not** inherit hop's
permissions (Accessibility, Full Disk Access, Calendar …): macOS asks for each in the plugin's
name. hop does not sandbox it otherwise. Install only plugins you trust.
