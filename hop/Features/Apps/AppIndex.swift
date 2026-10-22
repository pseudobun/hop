import AppKit
import CoreServices

nonisolated struct AppEntry: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case application, settingsPane, preferencePane }

    let path: String
    let name: String
    let bundleID: String?
    let alternateNames: [String]
    let kind: Kind
    let isGame: Bool

    var id: String { "app:" + (bundleID ?? path) }

    var openURL: URL {
        if kind == .settingsPane, let bundleID { return URL(string: "x-apple.systempreferences:\(bundleID)")! }
        return URL(fileURLWithPath: path)
    }
}

/// Scans the Raycast default app scopes (raycast-re spec-native.md §5).
nonisolated enum AppScanner {
    static var scopes: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Applications",
            "\(home)/Applications (Parallels)",
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications",
            "/System/Cryptexes/App/System/Applications",
            "/Library/PreferencePanes",
            "\(home)/Library/PreferencePanes",
        ]
    }

    static let coreServices = "/System/Library/CoreServices"
    /// Helper apps in CoreServices that are not agents but are not worth showing.
    static let hiddenHelpers: Set<String> = [
        "FamilyExtensionHost", "PIPAgent", "PeopleMessageService", "ShortcutsActions", "SystemIntents",
        "Rosetta 2 Updater", "WidgetKit Simulator", "Enhanced Logging", "Apple Diagnostics", "Language Chooser",
        "Erase Assistant", "Setup Assistant", "AVB Configuration", "Medical Imaging Calibrator",
    ]

    static let settingsExtensionsDir = "/System/Library/ExtensionKit/Extensions"
    static let excludedSettings: Set<String> = ["HomePrivacySettingsExtension.appex", "HeadphoneSettingsExtension.appex"]
    static let renamedSettings = ["PowerPreferences": "Battery"]

    /// Directories FSEvents should watch to keep the index fresh.
    static var watchedPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "\(home)/Applications", "/System/Applications"]
    }

    @concurrent static func scan() async -> [AppEntry] {
        var seen = Set<String>()
        var entries: [AppEntry] = []
        for scope in scopes {
            collect(in: URL(fileURLWithPath: scope), depth: 0, into: &entries, seen: &seen)
        }
        entries.append(contentsOf: settingsPanes())
        return entries
    }

    private static func collect(in dir: URL, depth: Int, into entries: inout [AppEntry], seen: inout Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for url in items {
            let ext = url.pathExtension
            if ext == "app" || ext == "prefPane" {
                let resolved = url.resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted, !resolved.contains("/AppTranslocation/") else { continue }
                let systemHelper = dir.path == coreServices
                if systemHelper && hiddenHelpers.contains(url.deletingPathExtension().lastPathComponent) { continue }
                if let e = entry(for: url, kind: ext == "app" ? .application : .preferencePane, skipAgents: systemHelper) {
                    entries.append(e)
                }
            } else if depth == 0, dir.path != coreServices,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // One level into folders such as Utilities or Setapp.
                collect(in: url, depth: 1, into: &entries, seen: &seen)
            }
        }
    }

    private static func infoPlist(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func flag(_ info: [String: Any], _ key: String) -> Bool {
        (info[key] as? Bool) == true || (info[key] as? String) == "1" || (info[key] as? Int) == 1
    }

    static func entry(for url: URL, kind: AppEntry.Kind, skipAgents: Bool = false) -> AppEntry? {
        let info = infoPlist(url) ?? [:]
        if flag(info, "LSBackgroundOnly") { return nil }
        if skipAgents && (flag(info, "LSUIElement") || flag(info, "NSUIElement")) { return nil }
        let display = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        var alternates: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let v = info[key] as? String, !v.isEmpty { alternates.append(v) }
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        alternates.append(fileName)
        if let extra = info["CFBundleAlternateNames"] as? [String] { alternates.append(contentsOf: extra) }
        let category = info["LSApplicationCategoryType"] as? String
        return AppEntry(path: url.path, name: display, bundleID: info["CFBundleIdentifier"] as? String,
                        alternateNames: alternates.filter { $0 != display },
                        kind: kind, isGame: category?.contains("games") == true)
    }

    /// "KeyboardSettings" → "Keyboard", "DateAndTime" → "Date And Time".
    static func prettifyPaneName(_ name: String) -> String {
        guard !name.contains(" ") else { return name }
        var n = name
        for suffix in ["SettingsExtension", "Settings", "Extension", "Pref"] where n.hasSuffix(suffix) && n.count > suffix.count {
            n.removeLast(suffix.count)
            break
        }
        var out = ""
        let chars = Array(n)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase { out.append(" ") }
            out.append(c)
        }
        return out
    }

    static func settingsPanes() -> [AppEntry] {
        let dir = URL(fileURLWithPath: settingsExtensionsDir)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [AppEntry] = []
        for url in items where url.pathExtension == "appex" && !excludedSettings.contains(url.lastPathComponent) {
            guard let info = infoPlist(url),
                  let ext = info["EXAppExtensionAttributes"] as? [String: Any],
                  ext["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  let attrs = ext["SettingsExtensionAttributes"] as? [String: Any],
                  attrs["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
                  let bundleID = info["CFBundleIdentifier"] as? String
            else { continue }
            var name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            if let renamed = renamedSettings[name] { name = renamed }
            name = prettifyPaneName(name)
            if name.hasSuffix("Extension") || name.hasSuffix("SettingsExtension") { continue }
            out.append(AppEntry(path: url.path, name: name, bundleID: bundleID, alternateNames: [],
                                kind: .settingsPane, isGame: false))
        }
        return out
    }
}

/// Keeps the app list current: full scan at launch, rescan on FSEvents (2 s latency).
final class AppIndex {
    private(set) var entries: [AppEntry] = []
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var scanTask: Task<Void, Never>?

    func start() {
        rescan()
        startWatching()
    }

    func rescan() {
        scanTask?.cancel()
        scanTask = Task {
            let result = await AppScanner.scan()
            guard !Task.isCancelled else { return }
            if result != entries {
                entries = result
                onChange?()
            }
        }
    }

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let index = Unmanaged<AppIndex>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { index.rescan() }
        }
        let paths = AppScanner.watchedPaths.filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
