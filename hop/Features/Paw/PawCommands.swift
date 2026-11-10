import AppKit

/// "Set Workspace": pick one of paw's setups (`paw setups --json`); ↵ runs `paw initiate <setup>`,
/// which opens that setup's apps and puts every window where its presets say.
/// paw: github.com/pseudobun/paw, a tiling window manager.
enum PawCommands {
    static func items(_ services: Services) -> [Item] {
        guard Paw.executable != nil else { return [] }
        return [
            Item(id: "paw.setWorkspace", title: "Set Workspace", subtitle: "Arrange apps for a paw setup",
                 aliases: ["initiate workspace", "reset workspace", "paw", "setup", "layout", "arrange windows"],
                 icon: .tile("rectangle.3.group.fill", Theme.chart2), accessory: "Command",
                 actions: [Action(title: "Choose Setup", symbol: "rectangle.3.group") { .push(PawSetupMode()) }],
                 pushesMode: true),
        ]
    }
}

nonisolated struct PawSetup: Sendable, Equatable {
    let name: String
    let displays: [String]
    let workspaces: [String]
    /// The connected displays are the ones this setup is for.
    let matches: Bool

    /// "home" → "Home", "laptop-only" → "Laptop Only".
    var label: String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

nonisolated enum Paw {
    /// The paw CLI: on PATH from `just install`, else inside the app.
    static var executable: String? {
        // `paw` also reaches a running paw Dev; paw-dev is there when only the dev build is installed.
        ["/opt/homebrew/bin/paw", "/usr/local/bin/paw", "/Applications/paw.app/Contents/MacOS/paw", "/opt/homebrew/bin/paw-dev"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func parse(_ json: String) -> [PawSetup] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return PawSetup(name: name, displays: d["displays"] as? [String] ?? [], workspaces: d["workspaces"] as? [String] ?? [],
                            matches: d["matches"] as? Bool ?? false)
        }
        .sorted { a, b in a.matches != b.matches ? a.matches : a.name < b.name }
    }

    static func setups() async -> [PawSetup] {
        guard let exe = executable, let r = try? await ProcessRunner.run(exe, ["setups", "--json"], timeout: .seconds(5)), r.ok
        else { return [] }
        return parse(r.out)
    }

    /// `paw update`: paw installs its downloaded version and restarts.
    @discardableResult
    static func update() async -> Bool {
        guard let exe = executable, let r = try? await ProcessRunner.run(exe, ["update"], timeout: .seconds(120)) else { return false }
        return r.ok
    }

    static func initiate(_ setup: String) async -> Bool {
        guard let exe = executable, let r = try? await ProcessRunner.run(exe, ["initiate", setup], timeout: .seconds(10)) else { return false }
        return r.ok
    }
}

final class PawSetupMode: Mode {
    let title: String? = "Set Workspace"
    let placeholder = "Search setups…"
    private var setups: [PawSetup] = []
    private var loaded = false
    private weak var context: LauncherContext?

    func didEnter(_ context: LauncherContext) {
        self.context = context
        context.setLoading(true)
        Task { @MainActor [weak self] in
            let list = await Paw.setups()
            guard let self else { return }
            setups = list
            loaded = true
            context.setLoading(false)
            context.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if loaded, setups.isEmpty {
            return [ResultSection(title: nil, items: [
                Item(id: "paw.none", title: "No setups", subtitle: "Add setups to ~/.config/paw/config.json5",
                     icon: .tile("exclamationmark.triangle.fill", Theme.chart4), actions: [], tracksFrecency: false),
            ])]
        }
        let items = setups.compactMap { s -> Item? in
            guard q.isEmpty || s.label.lowercased().contains(q) || s.displays.joined(separator: " ").lowercased().contains(q)
            else { return nil }
            let count = s.workspaces.count
            return Item(id: "paw.setup.\(s.name)", title: s.label,
                        subtitle: s.displays.joined(separator: " + ") + " · \(count) workspace\(count == 1 ? "" : "s")",
                        icon: .tile(s.displays.count > 1 ? "rectangle.on.rectangle" : "laptopcomputer", Theme.chart2),
                        accessory: "\(s.displays.count) display\(s.displays.count == 1 ? "" : "s")",
                        actions: [Action(title: "Arrange", symbol: "rectangle.3.group") {
                            Task { _ = await Paw.initiate(s.name) }
                            return .dismissWithHUD("Workspace: \(s.label)")
                        }],
                        tracksFrecency: false,
                        chip: s.matches ? Chip(text: "Connected", tone: .good) : nil)
        }
        return [ResultSection(title: nil, items: items)]
    }
}
