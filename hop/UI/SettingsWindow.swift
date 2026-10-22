import AppKit
import ServiceManagement
import SwiftUI

/// Settings, created on first open and released on close.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings))
            let w = NSWindow(contentViewController: host)
            w.title = "hop Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Search sensitivity", selection: $settings.data.sensitivity) {
                    Text("Low").tag(Sensitivity.low)
                    Text("Medium").tag(Sensitivity.medium)
                    Text("High").tag(Sensitivity.high)
                }
                Picker("Pop to root after", selection: $settings.data.popToRootSeconds) {
                    Text("Immediately").tag(0)
                    Text("30 seconds").tag(30)
                    Text("90 seconds").tag(90)
                    Text("3 minutes").tag(180)
                }
            }
            SettingsSections(settings: settings)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
