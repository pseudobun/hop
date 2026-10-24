import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

/// The macOS permissions hop's features need, with status checks and the
/// system prompts that grant them.
/// Nonisolated so the status checks can run off the main thread.
nonisolated enum Permission: CaseIterable {
    case accessibility, finderAutomation, downloads, fullDiskAccess, loginItem

    nonisolated enum Status { case granted, missing, unknown }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .finderAutomation: "Control Finder"
        case .downloads: "Downloads Folder"
        case .fullDiskAccess: "Full Disk Access"
        case .loginItem: "Open at Login"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: "Hyper Key, pasting from KeePassXC and the clipboard history"
        case .finderAutomation: "Empty Trash and removing protected apps"
        case .downloads: "Clear Downloads"
        case .fullDiskAccess: "Optional: remove app data in ~/Library/Containers when uninstalling"
        case .loginItem: "Start hop when you log in"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "hand.raised.fill"
        case .finderAutomation: "macwindow.on.rectangle"
        case .downloads: "arrow.down"
        case .fullDiskAccess: "externaldrive.fill"
        case .loginItem: "power"
        }
    }

    @MainActor var color: NSColor {
        switch self {
        case .accessibility: Theme.info
        case .finderAutomation: Theme.chart1
        case .downloads: Theme.chart5
        case .fullDiskAccess: Palette.neutral
        case .loginItem: Theme.good
        }
    }

    var isOptional: Bool { self == .fullDiskAccess }

    var settingsURL: URL {
        let pane = switch self {
        case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
        case .finderAutomation: "com.apple.preference.security?Privacy_Automation"
        case .downloads: "com.apple.preference.security?Privacy_FilesAndFolders"
        case .fullDiskAccess: "com.apple.preference.security?Privacy_AllFiles"
        case .loginItem: "com.apple.LoginItems-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    /// Current status without prompting. Some checks are IPC round trips; safe off the main thread.
    func status() -> Status {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .missing
        case .finderAutomation:
            switch Self.finderPermission(ask: false) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .missing
            default: return .unknown // not asked yet, or Finder not running
            }
        case .downloads:
            return PermissionLog.downloadsGranted.map { $0 ? .granted : .missing } ?? .unknown
        case .fullDiskAccess:
            // A TCC-protected file only readable with Full Disk Access.
            let probe = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari/Bookmarks.plist").path
            return FileManager.default.isReadableFile(atPath: probe) ? .granted : .missing
        case .loginItem:
            return SMAppService.mainApp.status == .enabled ? .granted : .missing
        }
    }

    /// Shows the system prompt where macOS has one; otherwise opens System Settings.
    @MainActor func request() async {
        switch self {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(settingsURL) }
        case .finderAutomation:
            let status = await Task.detached { Self.finderPermission(ask: true) }.value
            if status == OSStatus(errAEEventNotPermitted) { NSWorkspace.shared.open(settingsURL) }
        case .downloads:
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
            let ok = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: dir)) != nil }.value
            PermissionLog.downloadsGranted = ok
            if !ok { NSWorkspace.shared.open(settingsURL) }
        case .fullDiskAccess:
            NSWorkspace.shared.open(settingsURL)
        case .loginItem:
            ConfigEditor.setBool("openAtLogin", true)
            do { try SMAppService.mainApp.register() } catch { SMAppService.openSystemSettingsLoginItems() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` for Finder; may block, keep off the main thread when asking.
    nonisolated static func finderPermission(ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    /// Permissions still missing for the features turned on in the config.
    static func missing(for config: HopConfig) -> [Permission] {
        var needed: [Permission] = [.finderAutomation, .downloads, .loginItem]
        if config.hyperKey.enabled || config.keepass.enabled || config.clipboard.enabled
            || (config.snippets.enabled && config.snippets.expand) { needed.insert(.accessibility, at: 0) }
        if !config.general.openAtLogin { needed.removeAll { $0 == .loginItem } }
        return needed.filter { $0.status() != .granted }
    }
}

/// Flips a boolean in the user's config file in place, keeping comments and layout.
enum ConfigEditor {
    @discardableResult
    static func setBool(_ key: String, _ value: Bool) -> Bool {
        let url = AppSettings.defaultURL
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? Regex("(\\b\(key)\\s*:\\s*)(true|false)") else { return false }
        guard text.contains(regex) else { return false }
        text.replace(regex) { m in "\(m.output[1].substring ?? "")\(value)" }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}

/// Remembers answers macOS gives no API to query (Downloads access) and first launch.
nonisolated enum PermissionLog {
    private static var defaults: UserDefaults { .standard }

    static var downloadsGranted: Bool? {
        get { defaults.object(forKey: "PermissionDownloadsGranted") as? Bool }
        set { defaults.set(newValue, forKey: "PermissionDownloadsGranted") }
    }

    static var onboarded: Bool {
        get { defaults.bool(forKey: "Onboarded") }
        set { defaults.set(newValue, forKey: "Onboarded") }
    }
}

/// "Permissions": every permission with its status; ↵ shows the system prompt.
final class PermissionsMode: Mode {
    let title: String? = "Permissions"
    let tint: NSColor? = Theme.info
    let placeholder = "Grant what hop needs. ↵ asks macOS, Esc when done"
    private weak var context: LauncherContext?
    private let config: () -> HopConfig

    init(config: @escaping () -> HopConfig) { self.config = config }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        PermissionLog.onboarded = true
        // Statuses change while System Settings is open; refresh when hop comes back.
        Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(2))
                guard self.context != nil else { return }
                context.reload()
            }
        }
    }

    func didExit() { context = nil }

    func sections(for query: String) -> [ResultSection] {
        let config = config()
        let all = Permission.allCases
        _ = config
        let missing = all.filter { !$0.isOptional && $0.status() != .granted }
        var top: [Item] = []
        if !missing.isEmpty {
            top.append(Item(id: "perm.all", title: "Grant All", subtitle: missing.map(\.title).joined(separator: ", "),
                            icon: .tile("checkmark.shield.fill", Theme.good),
                            actions: [Action(title: "Ask for Each") { [weak self] in
                                guard let self else { return .stay }
                                context?.suppressAutoHide = true
                                for p in missing { await p.request() }
                                context?.suppressAutoHide = false
                                return .reload
                            }], tracksFrecency: false))
        }
        let rows = all.map { p in
            let status = p.status()
            let chip: Chip = switch status {
            case .granted: Chip(text: "Granted", tone: .good)
            case .missing: p.isOptional ? Chip(text: "Optional", tone: .neutral) : Chip(text: "Missing", tone: .warn)
            case .unknown: Chip(text: "Not asked", tone: .info)
            }
            return Item(id: "perm.\(p)", title: p.title, subtitle: p.purpose, icon: .tile(p.symbol, status == .granted ? Theme.good : p.color),

                        actions: [
                            Action(title: status == .granted ? "Open Settings" : "Grant") { [weak self] in
                                if status == .granted {
                                    NSWorkspace.shared.open(p.settingsURL)
                                } else {
                                    self?.context?.suppressAutoHide = true
                                    await p.request()
                                    self?.context?.suppressAutoHide = false
                                }
                                return .reload
                            },
                            Action(title: "Open in System Settings", shortcut: .ret(.command)) {
                                NSWorkspace.shared.open(p.settingsURL)
                                return .stay
                            },
                        ], tracksFrecency: false, chip: chip)
        }
        return [ResultSection(title: nil, items: top), ResultSection(title: "Permissions", items: rows)]
    }
}
