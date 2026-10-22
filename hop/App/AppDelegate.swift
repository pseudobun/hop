import AppKit
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
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
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isRunningTests else { return }

        let settings = AppSettings()
        let frecency = FrecencyStore(store: JSONStore(url: AppPaths.file("frecency.json")))
        let apps = AppIndex()
        services = Services(settings: settings, frecency: frecency, apps: apps)
        settingsWindow = SettingsWindowController(settings: settings)
        services.openSettings = { [weak self] in self?.settingsWindow.show() }

        root = RootMode(apps: apps, frecency: frecency, settings: settings) { [unowned self] in
            Registry.commands(services)
        }
        launcher = LauncherController(root: root)
        launcher.popToRootSeconds = { settings.data.popToRootSeconds }
        launcher.onItemPerformed = { item, index in
            if index == 0 && item.tracksFrecency { frecency.recordVisit(item.id) }
        }
        root.didEnter(launcher)

        apps.onChange = { [weak self] in
            self?.root.rebuild()
            if self?.launcher.isVisible == true { self?.launcher.reload() }
        }
        root.rebuild()
        apps.start()

        hotkey = GlobalHotkey { [weak self] in self?.launcher.toggle() }
        if !hotkey.register() { Log.app.error("Could not register ⌘Space") }

        statusItem = StatusItem(onOpen: { [weak self] in self?.launcher.show() },
                                onSettings: { [weak self] in self?.settingsWindow.show() })

        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "DebugShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                launcher.show(query: defaults.string(forKey: "DebugQuery"))
                if let path = defaults.string(forKey: "DebugSnapshotPath") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        await DebugSnapshot.capture(self.launcher.panel, to: path)
                    }
                }
            }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.show()
        return false
    }
}
