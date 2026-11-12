import AppKit
import os
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        CLI.runIfRequested(CommandLine.arguments)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private var serviceBag: Services!
    private var root: RootMode!
    private var launcherController: LauncherController!
    private var hotkey: GlobalHotkey!
    private var plugins: PluginManager!
    private var settingsWindow: SettingsController!
    private let bindings = HotkeyBindings()
    /// The `hotkeys` map and reserved hotkeys last handed to `bindings`.
    private var appliedBindings: (map: [String: String], reserved: [String])?
    /// The sub-mode a command hotkey last opened, so pressing it again hides the launcher.
    private weak var bindingMode: Mode?
    private var bindingKey: String?
    private var themesWatcher: FolderWatcher?
    /// The theme files last loaded, so a save that changes nothing doesn't rebuild every window.
    private var themesSignature: [String: Data] = [:]
    private let activity = SystemActivity()
    private var statusItem: StatusItem?
    #if DEBUG
    private var debugBackdrop: NSWindow?
    #endif
    private let startupIndicator = StartupIndicator()
    private var signalSources: [DispatchSourceSignal] = []
    private var ipc: HopIPCServer?
    private var syncingPlugins = false

    // Shortcuts to plugins hop itself drives (menu bar, IPC, debug flags).
    private var notes: NotesController? { services.notes }
    private var clipboard: ClipboardController? { services.clipboard }
    private var shelves: ShelfController? { services.shelves }
    private var calendar: CalendarController? { services.calendar }

    /// `hop shelf` and `hop update` reach the running hop here (see `HopIPC`).
    private func startIPC() {
        let server = HopIPCServer { [weak self] m in
            guard let self else { return .fail("hop is quitting") }
            switch m.verb {
            case .shelfAdd:
                guard let shelves else { return .fail("the Shelf plugin is off") }
                shelves.addFromCLI(m.paths ?? [])
                return .ok
            case .pluginsChanged:
                reloadInstalledPlugins()
                return .ok
            case .commands:
                var reply = HopIPC.Reply.ok
                reply.commands = Registry.commands(services).map { [$0.id, $0.title] }
                return reply
            case .updateInstall, .updateCheck:
                guard Updater.shared.isAvailable else { return .fail("this hop has no updater") }
                if m.verb == .updateInstall { Updater.shared.installNow() } else { Updater.shared.checkOnly() }
                return .ok
            }
        }
        server.start()
        ipc = server
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isRunningTests else { return }
        AppPaths.migrateLegacyData()
        installSignalHandlers()
        Theme.registerFonts()

        let settings = AppSettings()
        loadCustomThemes(folder: CustomThemes.folder(beside: settings.url), announce: false)
        Theme.variant = settings.data.general.theme
        let frecency = FrecencyStore(store: JSONStore(url: AppPaths.file("frecency.json")))
        let apps = AppIndex()
        serviceBag = Services(settings: settings, frecency: frecency, apps: apps)
        plugins = PluginManager(plugins: BuiltinPlugins.makeAll() + InstalledPlugins.load())
        plugins.usage = PluginUsage(store: JSONStore(url: AppPaths.file("plugin-usage.json")))
        services.plugins = plugins

        root = RootMode(apps: apps, frecency: frecency, settings: settings) { [unowned self] in
            Registry.commands(services)
        }
        root.plugins = plugins
        root.hotkeyProblems = { [weak self] in (self?.bindings.problems ?? []) + (self?.plugins.hotkeyProblems ?? []) }
        bindings.run = { [weak self] key in self?.runBinding(key) }
        let makePermissions: () -> Mode = { PermissionsMode { settings.data } }
        root.permissionsMode = makePermissions
        services.permissionsMode = makePermissions
        launcherController = LauncherController(root: root)
        settingsWindow = SettingsController(settings: settings, plugins: plugins)
        settingsWindow.onAction = { [weak self] in self?.runSettingsAction($0) }
        services.openSettings = { [weak self] page in
            self?.launcher.hide()
            self?.settingsWindow.show(page: page)
        }
        launcher.onOpenSettings = { [weak self] in self?.services.openSettings?(nil) }
        services.hideLauncher = { [weak self] in self?.launcher.hide() }
        launcher.popToRootSeconds = { settings.data.general.popToRootSeconds }
        launcher.keepQueryFor = { settings.data.general.keepQueryFor }
        launcher.onWillShow = { [weak self] in self?.plugins.launcherWillShow() }
        // A theme previewed in the picker lasts while the launcher is up.
        launcher.onDidHide = { [weak self] in self?.preview(theme: settings.data.general.theme) }
        services.previewTheme = { [weak self] in self?.preview(theme: $0) }
        services.reloadThemes = { [weak self] in self?.reloadCustomThemes() }
        themesWatcher = FolderWatcher(folder: CustomThemes.folder(beside: settings.url)) { [weak self] in
            self?.reloadCustomThemes()
        }
        launcher.onItemPerformed = { [weak self] item, index in
            if index == 0 && item.tracksFrecency { frecency.recordVisit(item.id) }
            self?.plugins.itemPerformed(item)
        }
        plugins.start(self)
        root.didEnter(launcher)

        apps.onChange = { [weak self] in
            guard let self else { return }
            root.rebuild()
            if launcher.isVisible { launcher.reload() } else { launcher.prepare() }
        }
        RunningApps.shared.onChange = { [weak self] in
            if self?.launcher.isVisible == true { self?.launcher.reload() }
        }
        RunningApps.shared.start()
        hotkey = GlobalHotkey { [weak self] in self?.launcher.toggle() }

        settings.onChange = { [weak self] old, new in self?.apply(new, previous: old) }
        settings.start()
        // Before apply: the menu bar bunny offers "Check for Updates…" only with an updater.
        Updater.shared.start(settings.data.updates)
        apply(settings.data, previous: nil)
        startIPC()

        activity.onChange = { [weak self] away in self?.plugins.setAway(away) }
        activity.start()

        root.rebuild()
        apps.start()
        startupIndicator.start()

        if !PermissionLog.onboarded && !ProcessInfo.processInfo.arguments.contains("-DebugShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.launcher.show()
                self?.launcher.push(makePermissions())
            }
        }

        #if DEBUG
        let defaults = UserDefaults.standard
        if let backdrop = defaults.string(forKey: "DebugBackdrop") { debugBackdrop = DebugSnapshot.showBackdrop(backdrop) }
        if defaults.bool(forKey: "DebugBenchmark") {
            let root = root!
            Task {
                await DebugBenchmark.run(launcher, probes: [
                    ("Permission.missing", { _ = Permission.missing(for: settings.data) }),
                    ("SpotlightHotkey.ownsCommandSpace", { _ = SpotlightHotkey.ownsCommandSpace }),
                    ("root sections, empty query", { _ = root.sections(for: "") }),
                    ("root sections, \"saf\"", { _ = root.sections(for: "saf") }),
                    ("clipboard show + hide", { [unowned self] in
                        guard let clipboard else { return }
                        clipboard.show(); clipboard.panel.displayIfNeeded(); clipboard.hide()
                    }),
                    ("clipboard type \"the\" (4 keys)", { [unowned self] in
                        guard let clipboard else { return }
                        if !clipboard.isVisible { clipboard.show() }
                        for q in ["t", "th", "the", ""] { clipboard.debugSearch(q); clipboard.panel.displayIfNeeded() }
                    }),
                    ("notes show + hide", { [unowned self] in
                        guard let notes else { return }
                        notes.show(); notes.panel.displayIfNeeded(); notes.hide()
                    }),
                    ("settings show + close", { [unowned self] in
                        settingsWindow.show(); settingsWindow.window.displayIfNeeded(); settingsWindow.window.close()
                    }),
                    ("emoji: open, type \"heart\"", { [unowned self] in
                        launcher.show()
                        launcher.push(EmojiCommands.mode(services))
                        for q in ["h", "he", "hea", "hear", "heart"] { launcher.setQuery(q); launcher.panel.displayIfNeeded() }
                        launcher.popToRoot()
                        launcher.hide()
                    }),
                ])
            }
        }
        if defaults.bool(forKey: "DebugClipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let clipboard else { return }
                clipboard.show()
                if let q = defaults.string(forKey: "DebugClipboardQuery") { clipboard.debugSearch(q) }
                if defaults.object(forKey: "DebugClipboardSelect") != nil { clipboard.debugSelect(defaults.integer(forKey: "DebugClipboardSelect")) }
                if defaults.bool(forKey: "DebugClipboardActions") { clipboard.debugOpenActions() }
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if self.debugBackdrop != nil {
                            await DebugSnapshot.captureRegion(around: clipboard.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(clipboard.panel, to: path)
                        }
                    }
                }
            }
        }
        if defaults.bool(forKey: "DebugNotes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let notes else { return }
                notes.show(newNote: defaults.bool(forKey: "DebugNotesNew"))
                if let q = defaults.string(forKey: "DebugNotesQuery") { notes.debugSearch(q) }
                if defaults.bool(forKey: "DebugNotesShortcuts") { notes.debugShowShortcuts() }
                if defaults.bool(forKey: "DebugNotesActions") { notes.debugOpenActions() }
                if let t = defaults.string(forKey: "DebugNotesType") {
                    notes.debugType(t.replacingOccurrences(of: "\\n", with: "\n"), title: defaults.string(forKey: "DebugNotesTitle"))
                    if defaults.bool(forKey: "DebugNotesHide") { notes.hide() }
                }
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if self.debugBackdrop != nil {
                            await DebugSnapshot.captureRegion(around: notes.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(notes.panel, to: path)
                        }
                    }
                }
            }
        }
        if let paths = defaults.string(forKey: "DebugShelf") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let shelves else { return }
                let items = paths.split(separator: ",").map { ShelfItem.classify(String($0)).kind == .link ? ShelfItem.link(String($0)) : ShelfItem.file(String($0)) }
                let main = NSScreen.main?.frame ?? .zero
                let shelf = shelves.newShelf(items, at: NSPoint(x: main.midX, y: main.midY))
                if let path = defaults.string(forKey: "DebugShelfRender") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { DebugSnapshot.render(shelf.panel, to: path) }
                }
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        if self.debugBackdrop != nil {
                            await DebugSnapshot.captureRegion(around: shelf.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(shelf.panel, to: path)
                        }
                    }
                }
            }
        }
        if let names = defaults.string(forKey: "DebugBirthdays") {
            // "Ana Novak,Bor|Cene": today's names, then tomorrow's after "|".
            let days = names.split(separator: "|", omittingEmptySubsequences: false).map { $0.split(separator: ",").map(String.init) }
            calendar?.debugBirthdays(today: days.first ?? [], tomorrow: days.count > 1 ? days[1] : [])
        }
        if defaults.bool(forKey: "DebugShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                launcher.show(query: defaults.string(forKey: "DebugQuery"))
                // "s|sy|sys": typed one after another, to check in-place row updates.
                for q in (defaults.string(forKey: "DebugQuerySteps") ?? "").split(separator: "|") { launcher.setQuery(String(q)) }
                if defaults.bool(forKey: "DebugActions") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.launcher.debugOpenActionPanel() }
                }
                if defaults.string(forKey: "DebugPush") == "permissions" { launcher.push(makePermissions()) }
                if defaults.string(forKey: "DebugPush") == "emoji" { launcher.push(EmojiCommands.mode(services)) }
                if defaults.string(forKey: "DebugPush") == "theme" { launcher.push(ThemeMode(services: services)) }
                if let page = defaults.string(forKey: "DebugSettings") {
                    settingsWindow.show(page: page)
                    if let path = defaults.string(forKey: "DebugSnapshotPath") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { DebugSnapshot.render(self.settingsWindow.window, to: path) }
                    }
                    return
                }
                if let q = defaults.string(forKey: "DebugPushQuery") { launcher.setQuery(q) }
                if defaults.string(forKey: "DebugPush") == "kill" { launcher.push(KillProcessMode(sensitivity: settings.data.general.sensitivity)) }
                if let path = defaults.string(forKey: "DebugLauncherRender") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { DebugSnapshot.render(self.launcher.panel, to: path) }
                }
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if self.debugBackdrop != nil {
                            await DebugSnapshot.captureRegion(around: self.launcher.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(self.launcher.panel, to: path)
                        }
                    }
                }
            }
        }
        #endif
    }

    /// Applies config changes: hotkey, plugins, login item, menu bar icon, commands.
    private func apply(_ config: HopConfig, previous: HopConfig?) {
        if previous?.general.theme != config.general.theme, !Theme.exists(config.general.theme) {
            HUD.shared.warn("No theme \"\(config.general.theme.rawValue)\", using OG")
        }
        if let previous, previous.general.theme != config.general.theme {
            // After the action that saved it has finished with the launcher.
            DispatchQueue.main.async { [weak self] in self?.applyTheme(config.general.theme) }
        }

        if previous?.general.hotkey != config.general.hotkey {
            let spec = HotkeySpec.parse(config.general.hotkey) ?? HotkeySpec.parse("cmd+space")!
            if HotkeySpec.parse(config.general.hotkey) == nil {
                Log.app.error("Invalid hotkey \(config.general.hotkey, privacy: .public), using cmd+space")
            }
            if !hotkey.register(keyCode: spec.keyCode, modifiers: spec.modifiers) {
                Log.app.error("Could not register hotkey \(config.general.hotkey, privacy: .public)")
            }
        }

        plugins.apply(config, previous: previous)
        if previous?.plugins.install != config.plugins.install { syncPlugins() }

        let reserved = [(owner: "the hop hotkey", hotkey: config.general.hotkey)] + plugins.reservedHotkeys(config)
        let signature = reserved.map { "\($0.owner)=\($0.hotkey)" }
        if appliedBindings?.map != config.hotkeys || appliedBindings?.reserved != signature {
            appliedBindings = (config.hotkeys, signature)
            bindings.apply(config.hotkeys, reserved: reserved)
            for p in bindings.problems { Log.app.error("hotkeys: \(p, privacy: .public)") }
        }

        Updater.shared.apply(config.updates)

        // A dev build never starts at login; the release hop does.
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if !AppPaths.isDev, config.general.openAtLogin != loginEnabled {
            do {
                if config.general.openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
            }
        }

        if config.general.menuBarIcon && statusItem == nil {
            statusItem = StatusItem(onOpen: { [weak self] in self?.launcher.show() },
                                    onNotes: { [weak self] in self?.notes?.show() },
                                    onClipboard: { [weak self] in self?.clipboard?.show() },
                                    onSettings: { [weak self] in self?.services.openSettings?(nil) },
                                    onConfig: { [weak self] in self?.services.openConfig() })
        } else if !config.general.menuBarIcon, let item = statusItem {
            item.remove()
            statusItem = nil
        }

        if previous != nil {
            root.rebuild()
            if launcher.isVisible { launcher.reload() }
            settingsWindow.configDidChange()
        }
    }

    private func runSettingsAction(_ action: SettingsAction) {
        switch action {
        case .openConfig: services.openConfig()
        case .revealConfig: NSWorkspace.shared.activateFileViewerSelecting([services.settings.url])
        case .permissions:
            launcher.show()
            if let make = services.permissionsMode { launcher.push(make()) }
        case .restart: _ = HopApp.restart()
        case .open(let url): if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .checkForUpdates: Updater.shared.installNow()
        case .showPage(let id): settingsWindow.show(page: id)
        case .installPlugin(let link): installPlugin(link)
        case .removePlugin(let id): removePlugin(id)
        }
    }

    /// A `hotkeys` binding fired: run that command, or open (or hide) that app.
    private func runBinding(_ key: String) {
        let lower = key.lowercased()
        if lower == "launcher" || lower == "hop" {
            launcher.toggle()
            return
        }
        if let binding = plugins.binding(named: lower) {
            binding.action()
            return
        }
        let commands = Registry.commands(services)
        let appKey = lower.hasPrefix("app:") ? String(key.dropFirst(4)) : key
        if !lower.hasPrefix("app:"),
           let item = commands.first(where: { $0.id == key }) ?? commands.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }),
           let action = item.actions.first {
            // Like the launcher hotkey: pressed again while its mode is in front, it hides.
            if launcher.isVisible, bindingKey == key, let mode = bindingMode, launcher.isShowing(mode) {
                launcher.hide()
                return
            }
            Task {
                let result = await action.perform()
                if case .push(let mode) = result {
                    launcher.show()
                    launcher.push(mode)
                    bindingMode = mode
                    bindingKey = key
                } else {
                    result.showHUD()
                }
            }
            return
        }
        let entries = services.apps.entries
        guard let app = entries.first(where: { $0.bundleID == appKey || $0.path == appKey })
            ?? entries.first(where: { $0.name.caseInsensitiveCompare(appKey) == .orderedSame }) else {
            HUD.shared.fail("No command or app “\(key)”")
            return
        }
        // Like Raycast's hotkey toggle: the app in front hides, otherwise it comes forward.
        if let id = app.bundleID, let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == id {
            front.hide()
        } else {
            AppLauncher.open(app.openURL)
        }
    }

    private func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler {
                NSApplication.shared.terminate(nil)
            }
            s.resume()
            signalSources.append(s)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupIndicator.stop()
        plugins?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcherController?.show()
        return false
    }
}

extension AppDelegate: PluginHost {
    var services: Services { serviceBag }
    var settings: AppSettings { services.settings }
    var launcher: LauncherController { launcherController }
    var isAway: Bool { activity.isAway }

    func rebuildRoot() { root?.rebuild() }

    func reloadLauncher() {
        if launcherController?.isVisible == true { launcher.reload() }
    }

    func reloadLauncherFromTop() {
        if launcherController?.isVisible == true { launcher.reloadFromTop() }
    }

    func present(_ mode: Mode) {
        launcher.show()
        launcher.push(mode)
    }

    func openSettings(_ page: String?) { services.openSettings?(page) }
    func openConfig() { services.openConfig() }
    func plugin<P: HopPlugin>(_ type: P.Type) -> P? { plugins?.plugin(type) }

    /// Views take their colours and fonts when they are built: the launcher is built again
    /// in `name`, keeping its mode, query and selection. Plugin windows follow in `applyTheme`.
    func preview(theme name: HopConfig.General.ThemeName, force: Bool = false) {
        guard force || Theme.variant != name else { return }
        Theme.variant = name
        plugins.themeDidChange(saved: false)
        launcher.retheme()
    }

    /// A saved theme: the launcher, plugin windows and root items in it, no restart.
    /// Open shelves keep theirs until closed; new ones use it.
    func applyTheme(_ name: HopConfig.General.ThemeName, force: Bool = false) {
        preview(theme: name, force: force)
        plugins.themeDidChange(saved: true)
        settingsWindow.retheme()
        root.rebuild()
        if launcher.isVisible { launcher.reload() } else { launcher.prepare() }
    }

    /// Reads `themes/` beside the config; problems show in the HUD when `announce`.
    /// False when nothing changed since the last load.
    @discardableResult
    private func loadCustomThemes(folder: URL, announce: Bool) -> Bool {
        let loaded = CustomThemes.load(from: folder)
        guard loaded.signature != themesSignature else { return false }
        themesSignature = loaded.signature
        Theme.registerFonts(loaded.fonts)
        Theme.setCustom(loaded.themes)
        for issue in loaded.issues { Log.app.error("theme: \(issue, privacy: .public)") }
        if announce, let first = loaded.issues.first { HUD.shared.warn("Theme: \(first)") }
        return true
    }

    /// A theme file was added, edited or removed: the picker and Settings list the new set,
    /// and when the theme in use is one of them, every window takes the edit at once.
    func reloadCustomThemes() {
        let settings = services.settings
        guard loadCustomThemes(folder: CustomThemes.folder(beside: settings.url), announce: true) else { return }
        let current = settings.data.general.theme
        if !current.isBuiltIn {
            applyTheme(current, force: true)
        } else {
            settingsWindow.retheme() // the theme list changed
            if launcher.isVisible { launcher.reload() }
        }
    }
}

extension AppDelegate {
    /// Downloads a plugin, asks before installing it, then starts it.
    func installPlugin(_ link: String) {
        if PluginInstaller.localArchive(link) == nil {
            do { HUD.shared.show("Downloading \(try PluginInstaller.parse(link).repository)…") } catch {
                HUD.shared.fail("\(error)")
                return
            }
        }
        Task {
            do {
                let staged = try await PluginInstaller.fetch(link)
                guard confirmInstall(staged) else {
                    PluginInstaller.discard(staged)
                    return
                }
                let directory = try PluginInstaller.commit(staged)
                PluginSync.recordInstall(PluginSync.link(for: staged.record, typed: link), settings: settings)
                plugins.remove(id: staged.manifest.id)
                plugins.add(ExternalPlugin(manifest: staged.manifest, directory: directory, record: staged.record), host: self)
                rebuildRoot()
                settingsWindow.show(page: staged.manifest.id)
                HUD.shared.show("Installed \(staged.manifest.name) \(staged.manifest.version)")
            } catch {
                HUD.shared.fail("Could not install: \(error)")
            }
        }
    }

    private func confirmInstall(_ staged: PluginInstaller.Staged) -> Bool {
        let m = staged.manifest, r = staged.record
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install \(m.name) \(m.version)?"
        let origin = r.repository.hasPrefix("local") ? r.repository : "github.com/\(r.repository) (\(r.tag))"
        var lines = ["From \(origin)" + (m.author.map { " by \($0)" } ?? "") + ".",
                     "A community plugin: not reviewed by hop."]
        let uses = m.permissions.lines
        lines.append("")
        lines.append(uses.isEmpty ? "It declares no network, clipboard, file or program use." : "It says it uses:\n" + uses.joined(separator: "\n"))
        lines.append("")
        lines.append("It runs as its own program with your user's access to files and the network. Install only plugins you trust.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func removePlugin(_ id: String) {
        guard let plugin = plugins.plugin(id: id), plugin.info.tier != .builtin else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(plugin.info.name)?"
        alert.informativeText = "Deletes the plugin and the secrets it keeps in the Keychain. Its settings stay in config.json5."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PluginSync.recordRemoval(id, settings: settings)
        plugins.remove(id: id)
        do {
            try PluginInstaller.remove(id: id)
            HUD.shared.show("Removed \(plugin.info.name)")
        } catch {
            HUD.shared.fail("Could not remove: \(error)")
        }
        rebuildRoot()
        settingsWindow.show(page: "plugins")
    }

    /// Installs what `plugins.install` lists and removes what it no longer lists. The config is
    /// the consent here, like any other code it names.
    func syncPlugins() {
        guard !syncingPlugins else { return }
        let plan = PluginSync.plan(settings.data, entries: InstalledPlugins.entries())
        guard !plan.isEmpty else { return }
        syncingPlugins = true
        Task {
            var installed: [String] = [], installedIDs: Set<String> = [], failed: [String] = []
            for link in plan.install {
                do {
                    let staged = try await PluginInstaller.fetch(link)
                    _ = try PluginInstaller.commit(staged)
                    installed.append(staged.manifest.name)
                    installedIDs.insert(staged.manifest.id)
                } catch {
                    failed.append(link)
                    Log.plugin.error("sync \(link, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            // A new tag of an installed plugin replaced it in place: nothing to remove.
            for id in plan.remove where !installedIDs.contains(id) {
                plugins.remove(id: id)
                do { try PluginInstaller.remove(id: id) } catch { failed.append(id) }
            }
            syncingPlugins = false
            reloadInstalledPlugins()
            if !failed.isEmpty {
                HUD.shared.fail("Plugins: could not sync \(failed.joined(separator: ", "))")
            } else {
                var parts: [String] = []
                if !installed.isEmpty { parts.append("installed \(installed.joined(separator: ", "))") }
                let removed = plan.remove.filter { !installedIDs.contains($0) }.count
                if removed > 0 { parts.append("removed \(removed)") }
                HUD.shared.show("Plugins: " + parts.joined(separator: ", "))
            }
        }
    }

    /// `hop plugin install` and `remove` changed the plugins folder: load it again.
    func reloadInstalledPlugins() {
        for plugin in plugins.plugins where plugin.info.tier != .builtin { plugins.remove(id: plugin.info.id) }
        for plugin in InstalledPlugins.load() { plugins.add(plugin, host: self) }
        rebuildRoot()
        if launcher.isVisible { launcher.reload() }
        settingsWindow.configDidChange()
    }
}
