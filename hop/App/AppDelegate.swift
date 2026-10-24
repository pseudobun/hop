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
    private let bindings = HotkeyBindings()
    private var snippetService: SnippetService!
    private let expander = SnippetExpander()
    private var expanderRetry: Timer?
    private var statusItem: StatusItem?
    #if DEBUG
    private var debugBackdrop: NSWindow?
    #endif
    private let hyper = HyperKeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isRunningTests else { return }
        Theme.registerFonts()

        let settings = AppSettings()
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
        notes = NotesController(settings: settings)
        notes.openConfig = { [weak self] in self?.services.openConfig() }
        services.notes = notes
        var clipDir = AppPaths.file("Clipboard")
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "DebugClipboardDir") { clipDir = URL(fileURLWithPath: dir) }
        #endif
        clipboardStore = ClipboardStore(dir: clipDir)
        clipboardStore.load()
        clipboardMonitor = ClipboardMonitor(store: clipboardStore) { settings.data.clipboard }
        clipboard = ClipboardController(store: clipboardStore, monitor: clipboardMonitor, settings: settings)
        services.clipboard = clipboard
        let snippetsFile = SnippetsFile(url: URL(fileURLWithPath: settings.data.snippets.file.expandingTilde))
        snippetService = SnippetService(file: snippetsFile, clipboard: clipboardStore)
        services.snippets = snippetService
        snippetService.presentArguments = { [weak self] mode in
            self?.launcher.show()
            self?.launcher.push(mode)
        }
        clipboard.saveSnippet = { text in
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return snippetsFile.append(Snippet(name: String(first.trimmingCharacters(in: .whitespaces).prefix(40)), text: text))
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
        bindings.run = { [weak self] key in self?.runBinding(key) }
        let makeFiles: () -> Mode = { FileSearchMode(settings: settings, frecency: frecency) }
        root.prefixModes = [(prefix: "kp ", make: makeKeePass), (prefix: "f ", make: makeFiles)]
        root.pathMode = makeFiles
        let makePermissions: () -> Mode = { PermissionsMode { settings.data } }
        root.permissionsMode = makePermissions
        services.permissionsMode = makePermissions
        launcher = LauncherController(root: root)
        launcher.popToRootSeconds = { settings.data.general.popToRootSeconds }
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

        settings.onChange = { [weak self] old, new in self?.apply(new, previous: old) }
        settings.start()
        apply(settings.data, previous: nil)

        root.rebuild()
        apps.start()

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
        if defaults.bool(forKey: "DebugShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                launcher.show(query: defaults.string(forKey: "DebugQuery"))
                if defaults.bool(forKey: "DebugActions") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.launcher.debugOpenActionPanel() }
                }
                if defaults.string(forKey: "DebugPush") == "permissions" { launcher.push(makePermissions()) }
                if defaults.string(forKey: "DebugPush") == "kill" { launcher.push(KillProcessMode(sensitivity: settings.data.general.sensitivity)) }
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

        if previous?.hotkeys != config.hotkeys || previous?.general.hotkey != config.general.hotkey
            || previous?.notes.hotkey != config.notes.hotkey || previous?.notes.enabled != config.notes.enabled
            || previous?.clipboard.hotkey != config.clipboard.hotkey || previous?.clipboard.enabled != config.clipboard.enabled {
            var reserved = [(owner: "the hop hotkey", hotkey: config.general.hotkey)]
            if config.notes.enabled { reserved.append((owner: "the notes hotkey", hotkey: config.notes.hotkey)) }
            if config.clipboard.enabled { reserved.append((owner: "the clipboard hotkey", hotkey: config.clipboard.hotkey)) }
            bindings.apply(config.hotkeys, reserved: reserved)
            for p in bindings.problems { Log.app.error("hotkeys: \(p, privacy: .public)") }
        }

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
                                    onConfig: { [weak self] in self?.services.openConfig() })
        } else if !config.general.menuBarIcon, let item = statusItem {
            item.remove()
            statusItem = nil
        }

        if previous != nil {
            root.rebuild()
            if launcher.isVisible { launcher.reload() }
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
        expanderRetry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.expander.start() else { return }
                self.expanderRetry?.invalidate()
                self.expanderRetry = nil
            }
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
        default: break
        }
        let commands = Registry.commands(services)
        let appKey = lower.hasPrefix("app:") ? String(key.dropFirst(4)) : key
        if !lower.hasPrefix("app:"),
           let item = commands.first(where: { $0.id == key }) ?? commands.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }),
           let action = item.actions.first {
            Task {
                switch await action.perform() {
                case .push(let mode):
                    launcher.show()
                    launcher.push(mode)
                case .dismissWithHUD(let text), .stayWithHUD(let text):
                    HUD.shared.show(text)
                case .dismiss, .stay, .pop, .reload:
                    break
                }
            }
            return
        }
        let entries = services.apps.entries
        guard let app = entries.first(where: { $0.bundleID == appKey || $0.path == appKey })
            ?? entries.first(where: { $0.name.caseInsensitiveCompare(appKey) == .orderedSame }) else {
            HUD.shared.show("No command or app “\(key)”", symbol: "exclamationmark.triangle.fill")
            return
        }
        // Like Raycast's hotkey toggle: the app in front hides, otherwise it comes forward.
        if let id = app.bundleID, let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == id {
            front.hide()
        } else {
            NSWorkspace.shared.open(app.openURL)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes?.saveNow()
        clipboardStore?.saveNow()
        hyper.stop()
        expander.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.show()
        return false
    }
}
