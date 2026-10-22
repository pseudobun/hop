import AppKit

/// Root search: apps, System Settings panes and commands, ranked with the Raycast
/// scorer and frecency, plus an inline calculator.
final class RootMode: Mode {
    let title: String? = nil
    let placeholder = "Search apps and commands…"

    private let apps: AppIndex
    private let frecency: FrecencyStore
    private let settings: AppSettings
    private let commands: () -> [Item]
    /// Query prefixes that jump straight into a sub-mode, e.g. "kp ".
    var prefixModes: [(prefix: String, make: () -> Mode)] = []
    weak var context: LauncherContext?

    private var items: [Item] = []
    private var candidates: [RankCandidate] = []
    private var commandIDs: Set<String> = []

    init(apps: AppIndex, frecency: FrecencyStore, settings: AppSettings, commands: @escaping () -> [Item]) {
        self.apps = apps
        self.frecency = frecency
        self.settings = settings
        self.commands = commands
    }

    /// Rebuild the candidate list after the app index or commands change.
    func rebuild() {
        let cmds = commands()
        commandIDs = Set(cmds.map(\.id))
        var newItems: [Item] = cmds
        var newCandidates = cmds.map {
            RankCandidate(id: $0.id, title: $0.title, subtitle: $0.subtitle, typeWeight: TypeWeight.command)
        }
        for entry in apps.entries {
            newItems.append(item(for: entry))
            newCandidates.append(RankCandidate(
                id: entry.id, title: entry.name, alternateTitles: entry.alternateNames,
                typeWeight: entry.kind == .application ? TypeWeight.application : TypeWeight.preference))
        }
        items = newItems
        candidates = newCandidates
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func sections(for query: String) -> [ResultSection] {
        if let (prefix, make) = prefixModes.first(where: { query.lowercased().hasPrefix($0.prefix) }) {
            let mode = make()
            let rest = String(query.dropFirst(prefix.count))
            DispatchQueue.main.async { [weak self] in
                self?.context?.push(mode)
                if !rest.isEmpty { self?.context?.setQuery(rest) }
            }
            return []
        }

        let now = Date()
        for i in candidates.indices { candidates[i].frecency = frecency.score(candidates[i].id, now: now) }

        if query.isEmpty { return emptySections() }

        let order = RootRanker.rank(candidates, query: SearchQuery(query), sensitivity: settings.data.sensitivity)
        let results = order.map { items[$0] }
        var sections: [ResultSection] = []
        let lower = query.lowercased()
        if let value = Calculator.evaluateIfExpression(query),
           !results.contains(where: { $0.title.lowercased().hasPrefix(lower) }) {
            sections.append(ResultSection(title: "Calculator", items: [calculatorItem(query, value)]))
        }
        sections.append(ResultSection(title: "Results", items: results))
        return sections
    }

    private func emptySections() -> [ResultSection] {
        var sections: [ResultSection] = []
        if let hint = SpotlightHotkey.hintItem() { sections.append(ResultSection(title: "Setup", items: [hint])) }

        let suggested = candidates.indices
            .filter { candidates[$0].frecency > 1 }
            .sorted { candidates[$0].frecency > candidates[$1].frecency }
            .prefix(5)
        let suggestedIDs = Set(suggested.map { candidates[$0].id })
        sections.append(ResultSection(title: "Suggestions", items: suggested.map { items[$0] }))

        let order = RootRanker.rankEmpty(candidates).filter { !suggestedIDs.contains(candidates[$0].id) }
        sections.append(ResultSection(title: "Commands", items: order.filter { commandIDs.contains(candidates[$0].id) }.map { items[$0] }))
        let appKinds = Set(apps.entries.filter { $0.kind == .application }.map(\.id))
        sections.append(ResultSection(title: "Applications", items: order.filter { appKinds.contains(candidates[$0].id) }.map { items[$0] }))
        return sections
    }

    private func calculatorItem(_ query: String, _ value: Decimal) -> Item {
        let text = Calculator.format(value)
        return Item(id: "calc", title: text, subtitle: query.trimmingCharacters(in: .whitespaces),
                    icon: .symbol("equal.square.fill"), accessory: "Calculator",
                    actions: [
                        Action(title: "Copy Answer") {
                            Pasteboard.copy(text)
                            return .dismissWithHUD("Copied \(text)")
                        },
                    ], tracksFrecency: false)
    }

    private func item(for entry: AppEntry) -> Item {
        let iconPath = entry.kind == .settingsPane ? "/System/Applications/System Settings.app" : entry.path
        let accessory = switch entry.kind {
        case .application: entry.isGame ? "Game" : "Application"
        case .settingsPane, .preferencePane: "System Settings"
        }
        var actions = [
            Action(title: entry.kind == .application ? "Open Application" : "Open Settings") {
                NSWorkspace.shared.open(entry.openURL)
                return .dismiss
            },
        ]
        if entry.kind == .application {
            actions.append(Action(title: "Show in Finder", shortcut: .ret(.command)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                return .dismiss
            })
            actions.append(Action(title: "Copy Path", shortcut: .cmd(".", .shift)) {
                Pasteboard.copy(entry.path)
                return .dismissWithHUD("Copied path")
            })
            if let bundleID = entry.bundleID {
                actions.append(Action(title: "Copy Bundle Identifier", shortcut: .cmd("c", .shift)) {
                    Pasteboard.copy(bundleID)
                    return .dismissWithHUD("Copied \(bundleID)")
                })
            }
        }
        return Item(id: entry.id, title: entry.name, icon: .file(iconPath), accessory: accessory, actions: actions)
    }
}

/// Spotlight owns ⌘Space until its symbolic hotkey (64) is disabled.
enum SpotlightHotkey {
    static var isEnabled: Bool {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let entry = all["64"] as? [String: Any]
        else { return true }
        if let on = entry["enabled"] as? Bool { return on }
        if let n = entry["enabled"] as? Int { return n != 0 }
        return true
    }

    static func hintItem() -> Item? {
        guard isEnabled else { return nil }
        return Item(id: "setup.spotlight", title: "Free ⌘Space for hop",
                    subtitle: "Turn off “Show Spotlight search” in Keyboard Shortcuts",
                    icon: .symbol("keyboard", tint: .systemOrange), accessory: "Setup",
                    actions: [
                        Action(title: "Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            return .dismiss
                        },
                    ], tracksFrecency: false)
    }
}
