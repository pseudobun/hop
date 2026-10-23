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

        root = RootMode(apps: apps, frecency: frecency, settings: settings) { [unowned self] in
            Registry.commands(services)
        }
        root.hyperError = { [weak self] in self?.hyper.lastError }
        root.prefixModes = [(prefix: "kp ", make: makeKeePass)]
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
        hotkey = GlobalHotkey { [weak self] in self?.launcher.toggle() }

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

    func applicationWillTerminate(_ notification: Notification) {
        hyper.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.show()
        return false
    }
}
