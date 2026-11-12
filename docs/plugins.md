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
| Review | pull request | none (Community) or hop's index (Verified) |

Core is what is left: the launcher, root search, apps, fallbacks, themes, hotkeys, Settings,
permissions, updates, the CLI and IPC.

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
| `launcherWillShow()`, `setAway(_:)`, `themeDidChange(saved:)`, `stop()` | lifecycle |

`PluginHost` gives a plugin the services, settings, launcher and other plugins
(`host.plugin(ClipboardPlugin.self)`).

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
| `action` | `command`, `id`, `payload` (a `callback` action) | a Response |
| `shutdown` | (notification) | exit |

| plugin → hop (notifications) | Params |
|---|---|
| `render` | a Response with `view`, and `command` to pick the open view |
| `hud` | `text`, `style?` |
| `loading` | `loading: true/false` |

An error reply (`{"error": {"code": -32000, "message": "…"}}`) shows as a red HUD. Requests time
out after 15 seconds.

A **Response** has any of: `view` (show or replace), `push` (open on top), `pop: true`, `hud`
(`{text, style: info|success|warn|fail}`), `dismiss: true` (hide the launcher).

A **View** is `{type: "list"|"grid", title?, placeholder?, filtering: "hop"|"plugin", columns?,
sections: [{title?, items}], items? (shorthand for one section), emptyText?, loading?}`. With
`filtering: "hop"` hop ranks the items as you type, like everywhere else; with `"plugin"` it sends
`query` once typing pauses.

An **Item** is `{id, title, subtitle?, icon?, accessory?, keywords?, actions}`. An icon is
`{symbol, color?}` (SF Symbol on a tile), `{emoji}` or `{file}`. `actions[0]` runs on ↵, the rest
are in ⌘K.

An **Action** is `{title, type, shortcut?, destructive?}` plus what its type needs:

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

- **Built-in**: reviewed in pull requests here, runs inside hop.
- **Verified**: installed from GitHub and listed in hop's plugin index
  (`pseudobun/hop-plugins`, `index.json`) with that archive's SHA-256.
- **Community**: any other GitHub link. hop shows where it comes from and what it says it uses,
  and asks before installing.

An installed plugin runs as you, with your access to files and the network, like any program you
download. hop spawns it as its own *responsible process*, so it does **not** inherit hop's
permissions (Accessibility, Full Disk Access, Calendar …): macOS asks for each in the plugin's
name. hop does not sandbox it otherwise. Install only plugins you trust.
