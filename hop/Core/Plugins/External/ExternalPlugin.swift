import AppKit
import os

/// Where an installed plugin came from, written next to it at install time (`install.json`).
nonisolated struct PluginInstallRecord: Codable, Equatable, Sendable {
    /// "owner/repo".
    var repository: String
    /// The release tag installed.
    var tag: String
    /// SHA-256 of the downloaded archive, hex.
    var sha256: String
    var installedAt: Date
}

/// A plugin installed from GitHub: its program runs as its own process (`PluginProcess`) and
/// hop draws what it describes (`PluginProtocol`).
final class ExternalPlugin: HopPlugin {
    let manifest: PluginManifest
    let directory: URL
    let record: PluginInstallRecord?
    let info: PluginInfo
    let settings: [SettingsSection]

    /// The program, made in `init`; `start` connects it to the launcher.
    private(set) var process: PluginProcess!
    private weak var host: PluginHost?
    /// Open views, newest last, so a `render` reaches the one it belongs to.
    private var modes: [WeakMode] = []
    private var timers: [Timer] = []
    private var lastSettings: JSONValue?
    /// Sent with `rootItems`: extra root commands and Upcoming items.
    private var rootItems: [PluginProtocol.Item] = []
    private var upcoming: [PluginProtocol.Item] = []
    /// The last root answer, for the query it answers.
    private var answer: (query: String, section: ResultSection?)?
    private var answerTask: Task<Void, Never>?
    /// Stands in for a command when root items, answers and app actions call back.
    private func pseudo(_ id: String) -> PluginManifest.Command { PluginManifest.Command(id: id, title: manifest.name) }

    private struct WeakMode { weak var mode: ExternalMode? }

    init(manifest: PluginManifest, directory: URL, record: PluginInstallRecord?) {
        self.manifest = manifest
        self.directory = directory
        self.record = record
        let color = manifest.color.flatMap(NSColor.init(hex:)) ?? Theme.info
        info = PluginInfo(id: manifest.id, name: manifest.name, summary: manifest.summary, symbol: manifest.symbol,
                          color: color, category: .installed, tier: .community,
                          version: manifest.version, author: manifest.author,
                          source: record.flatMap { $0.repository.hasPrefix("local") ? nil : "https://github.com/\($0.repository)" },
                          keywords: manifest.commands.map(\.title))
        settings = Self.settingsSections(manifest)
        let id = manifest.id
        let dataDir = AppPaths.file("PluginData").appending(path: id)
        process = PluginProcess(executable: directory.appending(path: manifest.entry), directory: directory, name: id) { [weak self] in
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            return PluginProtocol.Initialize(hopVersion: AppPaths.version, pluginID: id,
                                             preferences: self.map { $0.preferences($0.host?.settings.data ?? HopConfig()) } ?? [:],
                                             dataDir: dataDir.path, appearance: Theme.isLight ? "light" : "dark")
        }
        process.keepAlive = { [weak self] in self?.openModes.isEmpty == false }
        process.onNotification = { [weak self] method, params in self?.received(method, params) }
    }

    // MARK: Settings

    /// Config path of a preference: `plugins."dev.you.plugin".<id>`.
    static func path(_ manifest: PluginManifest, _ preference: PluginManifest.Preference) -> [String] {
        ["plugins", manifest.id, preference.id]
    }

    nonisolated static func keychainService(_ id: String) -> String { "\(AppPaths.bundleID).plugin.\(id)" }

    private static func settingsSections(_ manifest: PluginManifest) -> [SettingsSection] {
        var rows: [SettingsRow] = []
        for p in manifest.preferences {
            let kind: SettingsField.Kind = switch p.type {
            case .text: .text(placeholder: p.placeholder ?? "")
            case .secret: .secret(service: keychainService(manifest.id), account: p.id)
            case .toggle: .toggle
            case .number: .number(min: p.min ?? Int.min / 2, max: p.max ?? Int.max / 2)
            case .choice: .choices(p.options)
            case .list: .list(placeholder: p.placeholder ?? "")
            case .textarea: .multiline
            case .hotkey: .hotkey(optional: !p.required)
            }
            rows.append(.field(SettingsField(path: path(manifest, p), p.title, kind, help: p.help, hidden: p.hidden,
                                             fallback: p.default?.plain)))
        }
        var sections: [SettingsSection] = []
        if !rows.isEmpty { sections.append(SettingsSection("Settings", rows)) }
        var about: [SettingsRow] = []
        let lines = manifest.permissions.lines
        about.append(.info(SettingsInfo(label: "Says it uses", help: "Declared by the plugin; hop does not enforce it.",
                                        lines: { _ in lines.isEmpty ? ["Nothing declared"] : lines },
                                        button: "Remove", action: .removePlugin(manifest.id))))
        sections.append(SettingsSection("Plugin", about))
        return sections
    }

    /// The plugin's settings with defaults filled in and secrets read from the Keychain.
    func preferences(_ config: HopConfig) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let stored = config.plugins.settings[manifest.id]?.object ?? [:]
        for p in manifest.preferences {
            if p.type == .secret {
                if let secret = Keychain.read(service: Self.keychainService(manifest.id), account: p.id) { out[p.id] = .string(secret) }
            } else if let value = stored[p.id] ?? p.default {
                out[p.id] = value
            }
        }
        return out
    }

    // MARK: Lifecycle

    func start(_ host: PluginHost) {
        self.host = host
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        timers.forEach { $0.invalidate() }
        timers = []
        let current = config.plugins.settings[manifest.id]
        // New settings reach the program through `initialize`: start it again next time.
        if previous != nil, current != lastSettings { process.stop() }
        lastSettings = current
        guard enabled else {
            process.stop()
            return
        }
        for command in manifest.commands where command.kind == .background {
            guard let seconds = PluginManifest.seconds(command.interval) else { continue }
            let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runInBackground(command) }
            }
            timer.tolerance = seconds / 10
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        process?.stop()
    }

    func setAway(_ away: Bool) {
        if away { process?.stop() }
    }

    // MARK: Root

    func commands() -> [Item] {
        let root = pseudo("root")
        let extra = rootItems.map { item($0, command: root, mode: nil) }
        return extra + manifest.commands.filter { $0.kind != .background }.map { command in
            Item(id: "plugin.\(manifest.id).\(command.id)", title: command.title, subtitle: command.subtitle,
                 aliases: command.keywords, icon: .tile(command.symbol ?? manifest.symbol, info.color),
                 accessory: manifest.name,
                 actions: [Action(title: command.kind == .view ? "Open" : "Run", symbol: command.symbol ?? manifest.symbol) { [weak self] in
                     guard let self else { return .stay }
                     return await self.run(command)
                 }], pushesMode: command.kind == .view)
        }
    }

    func upcomingItems() -> [Item] {
        let root = pseudo("root")
        return upcoming.map { item($0, command: root, mode: nil) }
    }

    func appActions(_ entry: AppEntry) -> [Action] {
        manifest.appActions.map { a in
            let payload: JSONValue = .object(["name": .string(entry.name), "path": .string(entry.path),
                                              "bundleID": entry.bundleID.map(JSONValue.string) ?? .null])
            return action(PluginProtocol.Action(title: a.title, type: .callback, id: a.id, payload: payload),
                          command: pseudo("app"), mode: nil, symbol: a.symbol)
        }
    }

    /// Answers arrive after the query: hop shows the last one for this exact text and reloads
    /// the launcher when a new one comes.
    func answer(for query: String, isAmbiguous: Bool) -> ResultSection? {
        guard manifest.answers else { return nil }
        if let answer, answer.query == query { return answer.section }
        answerTask?.cancel()
        answerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            do {
                let value = try await process.request("answer", PluginProtocol.Answer(text: query), timeout: 5)
                guard !Task.isCancelled else { return }
                let result = value == .null ? nil
                    : try JSONDecoder().decode(PluginProtocol.AnswerResult.self, from: JSONEncoder().encode(value))
                let root = pseudo("answer")
                let section = result.flatMap { r in
                    r.items.isEmpty ? nil : ResultSection(title: r.title ?? manifest.name, items: r.items.map { item($0, command: root, mode: nil) })
                }
                answer = (query, section)
                if host?.launcher.query == query { host?.reloadLauncherFromTop() }
            } catch {
                answer = (query, nil)
            }
        }
        return nil
    }

    func prefixModes() -> [PrefixMode] {
        manifest.commands.compactMap { command in
            guard command.kind == .view, let prefix = command.prefix, !prefix.isEmpty else { return nil }
            return PrefixMode(prefix: prefix) { [unowned self] in ExternalMode(plugin: self, command: command, view: nil) }
        }
    }

    private func run(_ command: PluginManifest.Command) async -> ActionResult {
        if command.kind == .view { return .push(ExternalMode(plugin: self, command: command, view: nil)) }
        do {
            let response = try await request("run", PluginProtocol.Run(command: command.id))
            return result(of: response, command: command, from: nil)
        } catch {
            return .failWithHUD("\(manifest.name): \(error)")
        }
    }

    private func runInBackground(_ command: PluginManifest.Command) {
        guard host?.isAway != true else { return }
        Task {
            do {
                let response = try await request("run", PluginProtocol.Run(command: command.id, background: true))
                if let hud = response.hud { Self.show(hud) }
            } catch {
                Log.plugin.error("\(self.manifest.id, privacy: .public) \(command.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Talking to the program

    func request<P: Encodable & Sendable>(_ method: String, _ params: P) async throws -> PluginProtocol.Response {
        let value = try await process.request(method, params)
        if value == .null { return PluginProtocol.Response() }
        return try JSONDecoder().decode(PluginProtocol.Response.self, from: JSONEncoder().encode(value))
    }

    private var openModes: [ExternalMode] {
        modes = modes.filter { $0.mode != nil }
        return modes.compactMap(\.mode)
    }

    func opened(_ mode: ExternalMode) { modes.append(WeakMode(mode: mode)) }
    func closed(_ mode: ExternalMode) { modes.removeAll { $0.mode == nil || $0.mode === mode } }

    private func received(_ method: String, _ params: JSONValue?) {
        switch method {
        case "render":
            guard let params, let data = try? JSONEncoder().encode(params),
                  let response = try? JSONDecoder().decode(PluginProtocol.Response.self, from: data) else { return }
            let command = params["command"]?.string
            let target = openModes.last { command == nil || $0.command.id == command }
            target?.apply(response)
        case "hud":
            guard let params, let data = try? JSONEncoder().encode(params),
                  let hud = try? JSONDecoder().decode(PluginProtocol.HUDMessage.self, from: data) else { return }
            Self.show(hud)
        case "rootItems":
            guard let params, let data = try? JSONEncoder().encode(params),
                  let items = try? JSONDecoder().decode(PluginProtocol.RootItems.self, from: data) else { return }
            if let list = items.items { rootItems = list }
            if let list = items.upcoming { upcoming = list }
            host?.rebuildRoot()
            host?.reloadLauncherFromTop()
        case "loading":
            openModes.last?.setLoading(params?["loading"]?.bool ?? params?.bool ?? false)
        default:
            Log.plugin.notice("\(self.manifest.id, privacy: .public): unknown notification \(method, privacy: .public)")
        }
    }

    static func show(_ hud: PluginProtocol.HUDMessage) {
        switch hud.style {
        case .fail: HUD.shared.fail(hud.text)
        case .warn: HUD.shared.warn(hud.text)
        default: HUD.shared.show(hud.text)
        }
    }

    /// What the launcher does with a plugin's answer.
    func result(of response: PluginProtocol.Response, command: PluginManifest.Command, from mode: ExternalMode?) -> ActionResult {
        if let push = response.push { return .push(ExternalMode(plugin: self, command: command, view: push)) }
        if let view = response.view {
            if let mode {
                mode.apply(PluginProtocol.Response(view: view))
            } else {
                return .push(ExternalMode(plugin: self, command: command, view: view))
            }
        }
        if response.pop == true { return .pop }
        if let hud = response.hud {
            if response.dismiss == true { return hud.style == .fail ? .failWithHUD(hud.text) : .dismissWithHUD(hud.text) }
            return switch hud.style {
            case .fail: .failWithHUD(hud.text)
            case .warn: .warnWithHUD(hud.text)
            default: .stayWithHUD(hud.text)
            }
        }
        if response.dismiss == true { return .dismiss }
        return response.view != nil ? .reload : .stay
    }

    // MARK: Items

    func icon(_ icon: PluginProtocol.Icon?) -> ItemIcon? {
        guard let icon else { return nil }
        if let emoji = icon.emoji { return .emoji(emoji) }
        if let file = icon.file {
            let path = file.hasPrefix("/") || file.hasPrefix("~") ? file.expandingTilde : directory.appending(path: file).path
            return .imageFile(path)
        }
        if let symbol = icon.symbol { return .tile(symbol, icon.color.flatMap(NSColor.init(hex:)) ?? info.color) }
        return nil
    }

    func item(_ item: PluginProtocol.Item, command: PluginManifest.Command, mode: ExternalMode?) -> Item {
        var out = Item(id: "plugin.\(manifest.id).\(item.id)", title: item.title, subtitle: item.subtitle, aliases: item.keywords ?? [],
                       icon: icon(item.icon), accessory: item.accessory,
                       actions: item.actions.map { action($0, command: command, mode: mode) }, tracksFrecency: mode == nil,
                       pushesMode: item.actions.first?.type == .push)
        if let chip = item.chip {
            let tone: Chip.Tone = switch chip.tone {
            case "good": .good
            case "warn": .warn
            case "bad": .bad
            case "info": .info
            default: .neutral
            }
            out.chip = Chip(text: chip.text, tone: tone)
        }
        return out
    }

    private func action(_ a: PluginProtocol.Action, command: PluginManifest.Command, mode: ExternalMode?, symbol override: String? = nil) -> Action {
        let shortcut = a.shortcut.flatMap(KeyCombo.parse)
        let style: Action.Style = a.destructive == true ? .destructive : .normal
        weak var host = self.host
        let typeSymbol: String? = switch a.type {
        case .push: "chevron.right"
        case .callback: "bolt"
        case .reveal: "folder"
        default: nil
        }
        let symbol = override ?? typeSymbol
        let perform: () async -> ActionResult = { [weak self, weak mode] in
            guard let self else { return .stay }
            switch a.type {
            case .copy:
                Pasteboard.copy(a.value ?? "")
                return .dismissWithHUD("Copied")
            case .paste:
                host?.launcher.hide()
                if !(await Pasteboard.paste(a.value ?? "", concealed: false)) {
                    HUD.shared.show("Copied. Allow hop in Accessibility to paste")
                }
                return .stay
            case .open:
                guard let string = a.url, let url = URL(string: string) else { return .failWithHUD("No URL to open") }
                NSWorkspace.shared.open(url)
                return .dismiss
            case .openFile, .reveal:
                guard let path = a.path?.expandingTilde else { return .failWithHUD("No file to open") }
                let url = URL(fileURLWithPath: path)
                if a.type == .reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
                return .dismiss
            case .push:
                guard let view = a.view else { return .stay }
                return .push(ExternalMode(plugin: self, command: command, view: view))
            case .callback:
                do {
                    let response = try await request("action", PluginProtocol.ActionCall(command: command.id, id: a.id ?? "", payload: a.payload))
                    return result(of: response, command: command, from: mode)
                } catch {
                    return .failWithHUD("\(manifest.name): \(error)")
                }
            }
        }
        guard let confirm = a.confirm else { return Action(title: a.title, symbol: symbol, shortcut: shortcut, style: style, perform: perform) }
        let tint = info.color
        return Action(title: a.title, symbol: symbol, shortcut: shortcut, style: style) {
            .push(ConfirmMode(title: confirm.title ?? a.title, message: confirm.message, confirmTitle: confirm.button ?? a.title,
                              symbol: a.destructive == true ? "exclamationmark.triangle.fill" : "questionmark.circle.fill",
                              tint: tint, confirm: perform))
        }
    }
}

/// A view an installed plugin fills: a list or a grid, ranked by hop or by the plugin.
final class ExternalMode: Mode {
    let plugin: ExternalPlugin
    let command: PluginManifest.Command
    private var view: PluginProtocol.View?
    private weak var context: LauncherContext?
    private var lastQuery: String?
    private var queryTask: Task<Void, Never>?
    private var failure: String?

    init(plugin: ExternalPlugin, command: PluginManifest.Command, view: PluginProtocol.View?) {
        self.plugin = plugin
        self.command = command
        self.view = view
    }

    var title: String? { view?.title ?? command.title }
    var tint: NSColor? { plugin.info.color }
    var placeholder: String { view?.placeholder ?? "Search \(command.title)…" }
    var layout: ResultLayout { view?.type == .grid ? .grid(columns: view?.columns ?? 8) : .list }
    var isSecureInput: Bool { view?.secureInput == true }

    /// ↵ with nothing selected: the plugin gets the text.
    func submit(_ query: String) -> ActionResult? {
        guard view?.submit == true else { return nil }
        context?.setLoading(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await plugin.request("submit", PluginProtocol.Submit(command: command.id, text: query))
                context?.setLoading(false)
                follow(plugin.result(of: response, command: command, from: self))
            } catch {
                context?.setLoading(false)
                HUD.shared.fail("\(plugin.manifest.name): \(error)")
            }
        }
        return .stay
    }

    /// Does in the launcher what an answer that arrived later asks for.
    private func follow(_ result: ActionResult) {
        switch result {
        case .push(let mode): context?.push(mode)
        case .pop: context?.pop()
        case .dismiss, .dismissWithHUD:
            context?.dismiss()
            result.showHUD()
        case .reload: context?.reload()
        default: result.showHUD()
        }
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        plugin.opened(self)
        guard view == nil else { return }
        context.setLoading(true)
        let query = context.query
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await plugin.request("run", PluginProtocol.Run(command: command.id, query: query.isEmpty ? nil : query))
                self.context?.setLoading(false)
                follow(plugin.result(of: response, command: command, from: self))
            } catch {
                self.context?.setLoading(false)
                failure = "\(error)"
                self.context?.reload()
            }
        }
    }

    func didExit() {
        queryTask?.cancel()
        plugin.closed(self)
    }

    func apply(_ response: PluginProtocol.Response) {
        if let view = response.view {
            self.view = view
            failure = nil
            context?.setLoading(view.loading == true)
            context?.refreshChrome()
            context?.reload()
        }
        if let hud = response.hud { ExternalPlugin.show(hud) }
    }

    func setLoading(_ on: Bool) { context?.setLoading(on) }

    func sections(for query: String) -> [ResultSection] {
        if let failure {
            return [ResultSection(title: nil, items: [Item(id: "plugin.error", title: "\(plugin.manifest.name) did not answer",
                                                           subtitle: failure, icon: .tile("exclamationmark.triangle.fill", Theme.warn),
                                                           actions: [], tracksFrecency: false)])]
        }
        guard let view else { return [] }
        if view.filtering == .plugin, query != lastQuery {
            lastQuery = query
            sendQuery(query)
        }
        var sections: [ResultSection] = []
        for section in view.sections {
            var items = section.items
            if view.filtering == .hop, !query.isEmpty {
                let candidates = items.map { RankCandidate(id: $0.id, title: $0.title, subtitle: $0.subtitle,
                                                           keywords: $0.keywords ?? [], typeWeight: 0) }
                let sensitivity = plugin.hostSensitivity
                items = RootRanker.rank(candidates, query: SearchQuery(query), sensitivity: sensitivity).map { items[$0] }
            }
            guard !items.isEmpty else { continue }
            sections.append(ResultSection(title: section.title, items: items.map { plugin.item($0, command: command, mode: self) }))
        }
        if sections.isEmpty, let empty = view.emptyText, view.loading != true {
            sections = [ResultSection(title: nil, items: [Item(id: "plugin.empty", title: empty, icon: .symbol("tray"),
                                                               actions: [], tracksFrecency: false)])]
        }
        return sections
    }

    /// The plugin ranks: send the text once typing pauses.
    private func sendQuery(_ text: String) {
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            do {
                let response = try await plugin.request("query", PluginProtocol.Query(command: command.id, text: text))
                guard !Task.isCancelled else { return }
                apply(response)
            } catch {
                Log.plugin.error("\(self.plugin.manifest.id, privacy: .public) query: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension ExternalPlugin {
    var hostSensitivity: Sensitivity { host?.settings.data.general.sensitivity ?? .high }
}

extension NSColor {
    /// "#rrggbb" or "rrggbb".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension KeyCombo {
    /// "cmd+c", "cmd+shift+return", "ctrl+delete".
    static func parse(_ text: String) -> KeyCombo? {
        var modifiers: NSEvent.ModifierFlags = []
        var key: Key?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "return", "enter": key = .returnKey
            case "delete", "backspace": key = .delete
            case let c where c.count == 1: key = .character(c)
            default: return nil
            }
        }
        guard let key else { return nil }
        return KeyCombo(key: key, modifiers: modifiers)
    }
}
