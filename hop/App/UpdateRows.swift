import AppKit

/// "Update hop" and "Update paw" at the top of the empty launcher once a version is downloaded
/// (each app's `update.json`); ↵ installs it and restarts that app.
enum UpdateRows {
    static let pawBundleID = "com.pseudobun.paw"

    static func items() -> [Item] {
        var items: [Item] = []
        if Updater.shared.isAvailable, let v = Updater.shared.pending {
            items.append(Item(id: "update.hop", title: "Update hop to \(v)", subtitle: "Downloaded · ↵ installs it and restarts hop",
                              icon: .tile("arrow.down.circle.fill", Theme.info), accessory: "Update",
                              actions: [Action(title: "Install and Restart", symbol: "arrow.down.circle") {
                                  Updater.shared.installNow()
                                  return .dismiss
                              }], tracksFrecency: false))
        }
        if let p = PendingUpdate.read(at: PendingUpdate.url(bundleID: pawBundleID)), Paw.executable != nil, isNewerPaw(p) {
            items.append(Item(id: "update.paw", title: "Update paw to \(p.version)", subtitle: "Downloaded · ↵ installs it and restarts paw",
                              icon: .tile("arrow.down.circle.fill", Theme.info), accessory: "Update",
                              actions: [Action(title: "Install and Restart paw", symbol: "arrow.down.circle") {
                                  Task { await Paw.update() }
                                  return .dismissWithHUD("Updating paw to \(p.version)…")
                              }], tracksFrecency: false))
        }
        return items
    }

    /// paw clears its file once the version runs; this covers a paw that hasn't started since.
    private static func isNewerPaw(_ p: PendingUpdate.Info) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pawBundleID),
              let build = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return true }
        return (Int(p.build) ?? 0) > (Int(build) ?? 0)
    }
}

/// Root commands: "Update hop" checks, downloads and installs now; "Update Channel" picks
/// where updates come from.
enum UpdateCommands {
    static func items(_ services: Services) -> [Item] {
        let channel = services.settings.data.updates.channel
        return [
            Item(id: "hop.update", title: "Update hop", subtitle: Updater.shared.pending.map { "hop \($0) is ready · ↵ installs it and restarts hop" }
                    ?? "Check for a new version and install it (now \(AppPaths.version))",
                 aliases: ["update", "upgrade", "check for updates", "hop update"],
                 icon: .tile("arrow.down", Theme.info), accessory: "Command",
                 actions: [Action(title: "Update Now", symbol: "arrow.down.circle") {
                     guard Updater.shared.isAvailable else { return .warnWithHUD("Builds from source don't update; git pull && just dev") }
                     Updater.shared.installNow()
                     // The HUD answers: up to date, or the version it installs.
                     return .dismissWithHUD(Updater.shared.pending.map { "Installing hop \($0)…" } ?? "Checking for updates…")
                 }], tracksFrecency: false),
            Item(id: "hop.updateChannel", title: "Update Channel", subtitle: "\(UpdateChannelMode.label(channel)): where hop's updates come from",
                 aliases: ["beta", "stable", "release channel", "updates channel"],
                 icon: .tile("antenna.radiowaves.left.and.right", Theme.info), accessory: "Command",
                 actions: [Action(title: "Choose Channel", symbol: "antenna.radiowaves.left.and.right") {
                     .push(UpdateChannelMode(settings: services.settings))
                 }], pushesMode: true),
        ]
    }
}

/// Automatic, Beta or Stable; ↵ saves `updates.channel` and checks the new channel.
final class UpdateChannelMode: Mode {
    let title: String? = "Update Channel"
    let placeholder = "Choose where updates come from"
    var tint: NSColor? { Theme.info }
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    static func label(_ channel: String) -> String {
        switch channel {
        case "beta": "Beta"
        case "stable": "Stable"
        default: "Automatic"
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let current = settings.data.updates.channel
        let options: [(id: String, subtitle: String, symbol: String)] = [
            ("auto", "Follows the hop you run: betas while it is a beta (now \(AppPaths.version))", "wand.and.stars"),
            ("beta", "Stable versions and betas, betas first", "flask.fill"),
            ("stable", "Stable versions only; there is none yet, so no updates until 0.1.0", "checkmark.seal.fill"),
        ]
        let q = query.lowercased()
        let items = options.filter { q.isEmpty || Self.label($0.id).lowercased().contains(q) }.map { option in
            var item = Item(id: "updates.channel.\(option.id)", title: Self.label(option.id), subtitle: option.subtitle,
                            icon: .tile(option.symbol, Theme.info),
                            actions: [Action(title: "Use \(Self.label(option.id))", symbol: "checkmark") { [settings] in
                                guard settings.update(["updates", "channel"], to: ConfigEdit.literal(option.id)) else {
                                    return .failWithHUD("Could not save updates.channel")
                                }
                                return .dismissWithHUD("Updates: \(Self.label(option.id))")
                            }], tracksFrecency: false)
            if option.id == current { item.chip = Chip(text: "Current", tone: .info) }
            return item
        }
        return [ResultSection(title: nil, items: items)]
    }
}
