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

    private var services: Services!
    private var root: RootMode!
    private var launcher: LauncherController!
    private var hotkey: GlobalHotkey!
    private var notes: NotesController!
    private var notesHotkey: GlobalHotkey!
    private var clipboardStore: ClipboardStore!
    private var clipboardMonitor: ClipboardMonitor!
    private var clipboard: ClipboardController!
    private var clipboardHotkey: GlobalHotkey!
    private var shelves: ShelfController!
    private var shelfHotkeys: [GlobalHotkey] = []
    private var calendar: CalendarController!
    private var settingsWindow: SettingsController!
    private let messageWatcher = MessageCodeWatcher()
    private var messagesHotkey: GlobalHotkey!
    private let bindings = HotkeyBindings()
    /// The sub-mode a command hotkey last opened, so pressing it again hides the launcher.
    private weak var bindingMode: Mode?
    private var bindingKey: String?
    private var snippetService: SnippetService!
    private var wireGuardBar: WireGuardBar?
    private let expander = SnippetExpander()
    private var expanderRetry: Timer?
    private let activity = SystemActivity()
    private var statusItem: StatusItem?
    #if DEBUG
    private var debugBackdrop: NSWindow?
    #endif
    private let hyper = HyperKeyController()
    private let startupIndicator = StartupIndicator()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isRunningTests else { return }
        AppPaths.migrateLegacyData()
        installSignalHandlers()
        Theme.registerFonts()

        let settings = AppSettings()
        Theme.variant = settings.data.general.theme
        let frecency = FrecencyStore(store: JSONStore(url: AppPaths.file("frecency.json")))
        let apps = AppIndex()
        services = Services(settings: settings, frecency: frecency, apps: apps)
        services.hyper = hyper
        let keepass = KeePassManager(settings: settings)
        let pins = KeePassPins()
        let makeKeePass: () -> Mode = { [unowned self] in
            KeePassMode(manager: keepass, pins: pins, sensitivity: settings.data.general.sensitivity,
                        openConfig: { [weak self] in self?.services.openConfig() })
        }
        services.keepassMode = makeKeePass
        services.keepass = keepass
        makeNotes()
        var clipDir = AppPaths.file("Clipboard")
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "DebugClipboardDir") { clipDir = URL(fileURLWithPath: dir) }
        #endif
        clipboardStore = ClipboardStore(dir: clipDir)
        clipboardStore.load()
        clipboardMonitor = ClipboardMonitor(store: clipboardStore) { settings.data.clipboard }
        makeClipboard()
        shelves = ShelfController(settings: settings)
        shelves.onChange = { [weak self] in self?.root?.rebuild() }
        services.shelves = shelves
        calendar = CalendarController(settings: settings)
        calendar.onChange = { [weak self] in
            guard let self, launcher?.isVisible == true, launcher.query.isEmpty else { return }
            launcher.reload()
        }
        services.calendar = calendar
        shelfHotkeys = [
            GlobalHotkey { [weak self] in self?.shelves.newShelf() },
            GlobalHotkey { [weak self] in self?.shelves.newShelfFromClipboard() },
            GlobalHotkey { [weak self] in self?.shelves.reopenLast() },
        ]
        let snippetsFile = SnippetsFile(url: URL(fileURLWithPath: settings.data.snippets.file.expandingTilde))
        snippetService = SnippetService(file: snippetsFile, clipboard: clipboardStore)
        services.snippets = snippetService
        snippetService.presentArguments = { [weak self] mode in
            self?.launcher.show()
            self?.launcher.push(mode)
        }
        snippetsFile.onChange = { [weak self] in
            self?.updateExpanderKeywords()
            self?.root?.rebuild()
        }
        expander.onMatch = { [weak self] index, keyword in
            guard let self, index < snippetService.snippets.count else { return }
            snippetService.insert(snippetService.snippets[index], keyword: keyword)
        }
        snippetsFile.start()

        root = RootMode(apps: apps, frecency: frecency, settings: settings) { [unowned self] in
            Registry.commands(services)
        }
        root.hyperError = { [weak self] in self?.hyper.lastError }
        root.hotkeyProblems = { [weak self] in self?.bindings.problems ?? [] }
        root.upcoming = { [weak self] in self?.calendar.upcomingItems() ?? [] }
        bindings.run = { [weak self] key in self?.runBinding(key) }
        let makeFiles: () -> Mode = { FileSearchMode(settings: settings, frecency: frecency) }
        root.prefixModes = [(prefix: "kp ", make: makeKeePass), (prefix: "f ", make: makeFiles)]
        root.pathMode = makeFiles
        let makePermissions: () -> Mode = { PermissionsMode { settings.data } }
        root.permissionsMode = makePermissions
        services.permissionsMode = makePermissions
        launcher = LauncherController(root: root)
        settingsWindow = SettingsController(settings: settings)
        settingsWindow.onAction = { [weak self] in self?.runSettingsAction($0) }
        services.openSettings = { [weak self] page in
            self?.launcher.hide()
            self?.settingsWindow.show(page: page)
        }
        launcher.onOpenSettings = { [weak self] in self?.services.openSettings?(nil) }
        services.hideLauncher = { [weak self] in self?.launcher.hide() }
        launcher.popToRootSeconds = { settings.data.general.popToRootSeconds }
        launcher.keepQueryFor = { settings.data.general.keepQueryFor }
        launcher.onWillShow = { [weak self] in self?.calendar.launcherWillShow() }
        // A theme previewed in the picker lasts while the launcher is up.
        launcher.onDidHide = { [weak self] in self?.preview(theme: settings.data.general.theme) }
        services.previewTheme = { [weak self] in self?.preview(theme: $0) }
        let wireGuardBar = WireGuardBar()
        wireGuardBar.config = { settings.data.wireguard }
        wireGuardBar.onShowAll = { [weak self] in
            let wg = settings.data.wireguard
            self?.launcher.push(WireGuardMode(showFlags: wg.showFlags, sensitivity: settings.data.general.sensitivity,
                                              exclusive: wg.exclusive))
        }
        launcher.setStrip(wireGuardBar)
        self.wireGuardBar = wireGuardBar
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DebugWireGuardFocus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { wireGuardBar.debugFocus() }
        }
        #endif
        launcher.onItemPerformed = { item, index in
            if index == 0 && item.tracksFrecency { frecency.recordVisit(item.id) }
        }
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
        ExchangeRates.shared.onUpdate = { [weak self] in
            if self?.launcher.isVisible == true { self?.launcher.reload() }
        }
        hotkey = GlobalHotkey { [weak self] in self?.launcher.toggle() }
        clipboardHotkey = GlobalHotkey { [weak self] in
            self?.launcher.hide()
            self?.clipboard.toggle()
        }
        notesHotkey = GlobalHotkey { [weak self] in
            self?.launcher.hide()
            self?.notes.toggle()
        }
        messagesHotkey = GlobalHotkey { [weak self] in self?.runBinding("messages.pasteCode") }

        settings.onChange = { [weak self] old, new in self?.apply(new, previous: old) }
        settings.start()
        // Before apply: the menu bar bunny offers "Check for Updates…" only with an updater.
        Updater.shared.start(settings.data.updates)
        apply(settings.data, previous: nil)

        activity.onChange = { [weak self] away in self?.setAway(away) }
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
                ])
            }
        }
        if defaults.bool(forKey: "DebugClipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                clipboard.show()
                if let q = defaults.string(forKey: "DebugClipboardQuery") { clipboard.debugSearch(q) }
                if defaults.object(forKey: "DebugClipboardSelect") != nil { clipboard.debugSelect(defaults.integer(forKey: "DebugClipboardSelect")) }
                if defaults.bool(forKey: "DebugClipboardActions") { clipboard.debugOpenActions() }
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if self.debugBackdrop != nil {
                            await DebugSnapshot.captureRegion(around: self.clipboard.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(self.clipboard.panel, to: path)
                        }
                    }
                }
            }
        }
        if defaults.bool(forKey: "DebugNotes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
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
                            await DebugSnapshot.captureRegion(around: self.notes.panel, padding: 60, to: path)
                        } else {
                            await DebugSnapshot.capture(self.notes.panel, to: path)
                        }
                    }
                }
            }
        }
        if let paths = defaults.string(forKey: "DebugShelf") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
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
            calendar.debugBirthdays(today: days.first ?? [], tomorrow: days.count > 1 ? days[1] : [])
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

    /// Applies config changes: hotkey, login item, menu bar icon, feature commands.
    private func apply(_ config: HopConfig, previous: HopConfig?) {
        if let previous, previous.general.theme != config.general.theme {
            // After the action that saved it has finished with the launcher.
            DispatchQueue.main.async { [weak self] in self?.applyTheme(config.general.theme) }
        }
        if previous?.hyperKey != config.hyperKey {
            hyper.update(enabled: config.hyperKey.enabled, quickPressEscape: config.hyperKey.quickPressEscape)
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

        if previous?.notes.enabled != config.notes.enabled || previous?.notes.hotkey != config.notes.hotkey {
            if config.notes.enabled, let spec = HotkeySpec.parse(config.notes.hotkey) {
                if !notesHotkey.register(keyCode: spec.keyCode, modifiers: spec.modifiers) {
                    Log.app.error("Could not register notes hotkey \(config.notes.hotkey, privacy: .public)")
                }
            } else {
                if config.notes.enabled { Log.app.error("Invalid notes hotkey \(config.notes.hotkey, privacy: .public)") }
                notesHotkey.unregister()
                notes.hide()
            }
        }
        if previous != nil && previous?.notes.folder != config.notes.folder { notes.folderChanged() }

        if previous?.snippets != config.snippets {
            let url = URL(fileURLWithPath: config.snippets.file.expandingTilde)
            if previous != nil && snippetService.file.url != url {
                snippetService.file.url = url
                snippetService.file.start()
            }
            expander.withinWords = config.snippets.expandWithinWords
            expander.disabledApps = Set(config.snippets.disabledApps)
            updateExpander(config.snippets)
        }

        if previous?.clipboard != config.clipboard {
            if config.clipboard.enabled {
                clipboardMonitor.start()
                clipboardStore.prune(keepDays: config.clipboard.keepDays, maxItems: config.clipboard.maxItems)
            } else {
                clipboardMonitor.stop()
                clipboard.hide()
            }
            if config.clipboard.enabled, let spec = HotkeySpec.parse(config.clipboard.hotkey) {
                if !clipboardHotkey.register(keyCode: spec.keyCode, modifiers: spec.modifiers) {
                    Log.app.error("Could not register clipboard hotkey \(config.clipboard.hotkey, privacy: .public)")
                }
            } else {
                if config.clipboard.enabled { Log.app.error("Invalid clipboard hotkey \(config.clipboard.hotkey, privacy: .public)") }
                clipboardHotkey.unregister()
            }
        }

        if previous?.calendar != config.calendar { calendar.apply(config.calendar) }

        if previous?.messages != config.messages {
            messageWatcher.apply(config.messages)
            let spec = config.messages.pasteHotkey
            if config.messages.enabled, !spec.isEmpty, let parsed = HotkeySpec.parse(spec) {
                if !messagesHotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) {
                    Log.app.error("Could not register messages hotkey \(spec, privacy: .public)")
                }
            } else {
                if config.messages.enabled, !spec.isEmpty { Log.app.error("Invalid messages hotkey \(spec, privacy: .public)") }
                messagesHotkey.unregister()
            }
        }

        if previous?.emoji != config.emoji {
            // ":" like Slack and GitHub shortcodes: ":fire" searches emoji for "fire".
            root.prefixModes.removeAll { $0.prefix == ":" }
            if config.emoji.enabled {
                root.prefixModes.append((prefix: ":", make: { [unowned self] in EmojiCommands.mode(services) }))
            }
        }

        if previous?.translate != config.translate {
            // "tr hvala za vse" opens Translate with that text.
            root.prefixModes.removeAll { $0.prefix == "tr " }
            if config.translate.enabled {
                root.prefixModes.append((prefix: "tr ", make: { [unowned self] in TranslateCommands.mode(services) }))
            }
        }

        if previous?.shelf != config.shelf {
            shelves.apply(config.shelf)
            let specs = [config.shelf.hotkey, config.shelf.clipboardHotkey, config.shelf.reopenHotkey]
            for (hotkey, spec) in zip(shelfHotkeys, specs) {
                guard config.shelf.enabled, !spec.isEmpty else {
                    hotkey.unregister()
                    continue
                }
                if let parsed = HotkeySpec.parse(spec) {
                    if !hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) {
                        Log.app.error("Could not register shelf hotkey \(spec, privacy: .public)")
                    }
                } else {
                    Log.app.error("Invalid shelf hotkey \(spec, privacy: .public)")
                    hotkey.unregister()
                }
            }
        }

        if previous?.hotkeys != config.hotkeys || previous?.general.hotkey != config.general.hotkey
            || previous?.notes.hotkey != config.notes.hotkey || previous?.notes.enabled != config.notes.enabled
            || previous?.clipboard.hotkey != config.clipboard.hotkey || previous?.clipboard.enabled != config.clipboard.enabled
            || previous?.shelf != config.shelf || previous?.messages != config.messages {
            var reserved = [(owner: "the hop hotkey", hotkey: config.general.hotkey)]
            if config.notes.enabled { reserved.append((owner: "the notes hotkey", hotkey: config.notes.hotkey)) }
            if config.clipboard.enabled { reserved.append((owner: "the clipboard hotkey", hotkey: config.clipboard.hotkey)) }
            if config.shelf.enabled {
                for (owner, spec) in [("shelf.hotkey", config.shelf.hotkey), ("shelf.clipboardHotkey", config.shelf.clipboardHotkey),
                                      ("shelf.reopenHotkey", config.shelf.reopenHotkey)] where !spec.isEmpty {
                    reserved.append((owner: owner, hotkey: spec))
                }
            }
            if config.messages.enabled && !config.messages.pasteHotkey.isEmpty {
                reserved.append((owner: "messages.pasteHotkey", hotkey: config.messages.pasteHotkey))
            }
            bindings.apply(config.hotkeys, reserved: reserved)
            for p in bindings.problems { Log.app.error("hotkeys: \(p, privacy: .public)") }
        }

        Updater.shared.apply(config.updates)

        let loginEnabled = SMAppService.mainApp.status == .enabled
        if config.general.openAtLogin != loginEnabled {
            do {
                if config.general.openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
            }
        }

        if config.general.menuBarIcon && statusItem == nil {
            statusItem = StatusItem(onOpen: { [weak self] in self?.launcher.show() },
                                    onNotes: { [weak self] in self?.notes.show() },
                                    onClipboard: { [weak self] in self?.clipboard.show() },
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
        case .checkForUpdates: Updater.shared.checkNow()
        }
    }

    private func updateExpanderKeywords() {
        expander.keywords = snippetService.snippets.enumerated().compactMap { i, s in s.keyword.map { ($0, i) } }
    }

    /// Starts the expander when wanted; without Accessibility it retries until granted.
    private func updateExpander(_ config: HopConfig.Snippets) {
        expanderRetry?.invalidate()
        expanderRetry = nil
        guard config.enabled && config.expand else {
            expander.stop()
            return
        }
        updateExpanderKeywords()
        if expander.start() { return }
        Log.app.notice("snippets: expansion waits for Accessibility")
        guard !activity.isAway else { return }
        let retry = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.expander.start() else { return }
                self.expanderRetry?.invalidate()
                self.expanderRetry = nil
            }
        }
        retry.tolerance = 2
        RunLoop.main.add(retry, forMode: .common)
        expanderRetry = retry
    }

    /// Screen locked, asleep or another user in front: periodic work stops until return.
    private func setAway(_ away: Bool) {
        clipboardMonitor.isPaused = away
        calendar.isPaused = away
        if away {
            expanderRetry?.invalidate()
            expanderRetry = nil
        } else if !expander.isRunning {
            // Starts it now if Accessibility was granted meanwhile, otherwise retries again.
            updateExpander(services.settings.data.snippets)
        }
    }

    /// A `hotkeys` binding fired: run that command, or open (or hide) that app.
    private func runBinding(_ key: String) {
        let lower = key.lowercased()
        switch lower {
        case "launcher", "hop": launcher.toggle(); return
        case "notes.open", "notes": notes.toggle(); return
        case "notes.new", "new note": launcher.hide(); notes.show(newNote: true); return
        case "clipboard.history", "clipboard history", "clipboard": launcher.hide(); clipboard.toggle(); return
        case "shelf.new", "new shelf", "shelf": shelves.newShelf(); return
        case "shelf.clipboard", "new shelf from clipboard": shelves.newShelfFromClipboard(); return
        case "shelf.reopen", "reopen shelf": shelves.reopenLast(); return
        default: break
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
                switch await action.perform() {
                case .push(let mode):
                    launcher.show()
                    launcher.push(mode)
                    bindingMode = mode
                    bindingKey = key
                case .dismissWithHUD(let text), .stayWithHUD(let text):
                    HUD.shared.show(text)
                case .failWithHUD(let text):
                    HUD.shared.fail(text)
                case .warnWithHUD(let text):
                    HUD.shared.warn(text)
                case .dismiss, .stay, .pop, .reload:
                    break
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
        notes?.saveNow()
        clipboardStore?.saveNow()
        shelves?.saveNow()
        hyper.stop()
        expander.stop()
        messageWatcher.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.show()
        return false
    }
}

extension AppDelegate {
    func makeNotes() {
        notes = NotesController(settings: services.settings)
        notes.openConfig = { [weak self] in self?.services.openConfig() }
        services.notes = notes
    }

    func makeClipboard() {
        clipboard = ClipboardController(store: clipboardStore, monitor: clipboardMonitor, settings: services.settings)
        clipboard.saveSnippet = { [weak self] text in
            guard let file = self?.snippetService?.file else { return false }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return file.append(Snippet(name: String(first.trimmingCharacters(in: .whitespaces).prefix(40)), text: text))
        }
        services.clipboard = clipboard
    }

    /// Views take their colours and fonts when they are built: the launcher is built again
    /// in `name`, keeping its mode, query and selection. Notes and Clipboard follow in `applyTheme`.
    func preview(theme name: HopConfig.General.ThemeName) {
        guard Theme.variant != name else { return }
        Theme.variant = name
        wireGuardBar?.retheme()
        launcher.retheme()
    }

    /// A saved theme: the launcher, Notes, Clipboard and root items in it, no restart.
    /// Open shelves keep theirs until closed; new ones use it.
    func applyTheme(_ name: HopConfig.General.ThemeName) {
        preview(theme: name)
        let notesShown = notes.isVisible, clipboardShown = clipboard.isVisible
        notes.hide()
        clipboard.hide()
        makeNotes()
        makeClipboard()
        if notesShown { notes.show() }
        if clipboardShown { clipboard.show() }
        settingsWindow.retheme()
        root.rebuild()
        if launcher.isVisible { launcher.reload() } else { launcher.prepare() }
    }
}
