import AppKit

/// KeePassXC: search .kdbx databases and copy passwords, usernames and TOTP codes.
final class KeePassPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "keepass", name: "KeePassXC", summary: "Search and copy passwords from .kdbx databases.", symbol: "key.fill",
                   color: Palette.keepass, category: .integrations, enabledPath: ["keepass", "enabled"], enabledByDefault: false)
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("keepass.enabled", "KeePassXC", .toggle),
                .info(SettingsInfo(
                    label: "Databases",
                    help: "Paths, key files and where each master password comes from live in the config.",
                    lines: { config in
                        config.keepass.allDatabases.map { "\($0.label)  ·  \($0.path)  ·  \($0.password.rawValue)" }
                    },
                    button: "Edit in Config", action: .openConfig)),
                .setting("keepass.favicons", "Site icons", .toggle, "Fetched straight from each entry's website and cached."),
            ]),
            SettingsSection("Locking", [
                .setting("keepass.autoLock", "Lock automatically", .toggle,
                  "On sleep, screen lock and after the minutes below. Off: a database stays open until ⌘L or quitting hop."),
                .setting("keepass.lockAfterMinutes", "Lock after", .number(min: -1, max: 1_440, unit: "min"), "-1: only on sleep or screen lock."),
            ]),
            SettingsSection("Advanced", [
                .setting("keepass.cli", "keepassxc-cli path", .text(placeholder: "found automatically"), check: SettingsChecks.executable),
                .setting("keepass.cliAccess", "Allow `hop kp get`", .toggle, "Lets the CLI (and agents) print passwords, TOTP codes and notes."),
            ]),
        ]
    }

    init() {}

    private(set) var manager: KeePassManager!
    private let pins = KeePassPins()
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        manager = KeePassManager(settings: host.settings)
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        manager?.apply(config.keepass, enabled: enabled)
    }

    func mode() -> Mode {
        KeePassMode(manager: manager, pins: pins, sensitivity: host!.settings.data.general.sensitivity,
                    openConfig: { [weak host] in host?.openConfig() })
    }

    func commands() -> [Item] { KeePassCommands.items(host!.services) }
    func prefixModes() -> [PrefixMode] { [PrefixMode(prefix: "kp ") { [unowned self] in mode() }] }
}

extension Services {
    var keepass: KeePassManager? { plugin(KeePassPlugin.self)?.manager }
    var keepassMode: (() -> Mode)? { plugin(KeePassPlugin.self).map { plugin in { plugin.mode() } } }
}
