import AppKit

/// Finds app leftovers in ~/Library by bundle id (and app group ids).
nonisolated enum LeftoverScanner {
    static let directories = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
        "Library/Group Containers", "Library/Saved Application State", "Library/HTTPStorages",
        "Library/LaunchAgents", "Library/Logs", "Library/WebKit",
    ]

    static func matches(_ name: String, bundleID: String, groups: [String]) -> Bool {
        let n = name.lowercased(), bid = bundleID.lowercased()
        if n == bid || n.hasPrefix(bid + ".") { return true } // folder, .plist, .savedState, .binarycookies
        if groups.contains(where: { n == $0.lowercased() }) { return true }
        return false
    }

    static func scan(bundleID: String, groups: [String] = [], home: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in directories {
            let base = home.appending(path: dir, directoryHint: .isDirectory)
            guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for name in names where matches(name, bundleID: bundleID, groups: groups) {
                found.append(base.appending(path: name))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// App group identifiers from the bundle's code-signing entitlements.
    static func appGroups(of app: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return ents["com.apple.security.application-groups"] as? [String] ?? []
    }
}

/// Homebrew cask that installed an app, if any.
nonisolated enum BrewCask {
    static let caskroom = "/opt/homebrew/Caskroom"
    static let brew = "/opt/homebrew/bin/brew"

    static func token(forApp appName: String) -> String? {
        let fm = FileManager.default
        guard let tokens = try? fm.contentsOfDirectory(atPath: caskroom) else { return nil }
        let needle = "\"\(appName).app\""
        for token in tokens {
            let meta = "\(caskroom)/\(token)/.metadata"
            guard let e = fm.enumerator(atPath: meta) else { continue }
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix("/Casks/\(token).json") || rel.hasSuffix("/Casks/\(token).rb") else { continue }
                if let text = try? String(contentsOfFile: "\(meta)/\(rel)", encoding: .utf8), text.contains(needle) {
                    return token
                }
            }
        }
        return nil
    }

    static func uninstall(_ token: String) async -> Bool {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let r = try? await ProcessRunner.run(brew, ["uninstall", "--cask", token], environment: env, timeout: .seconds(300))
        return r?.ok == true
    }
}

nonisolated enum Trash {
    /// Move to Trash; fall back to Finder for protected or root-owned items.
    static func move(_ url: URL) async -> Bool {
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return true }
        let script = "tell application \"Finder\" to delete (POSIX file \(AppleScript.quoted(url.path)))"
        let r = try? await AppleScript.run(script)
        return r?.ok == true
    }
}

/// Pick an app to uninstall.
final class UninstallPickerMode: Mode {
    let title: String? = "Uninstall"
    let tint: NSColor? = Theme.warn
    let placeholder = "Search applications to uninstall…"
    private let services: Services

    init(services: Services) { self.services = services }

    private var apps: [AppEntry] {
        services.apps.entries.filter { $0.kind == .application && UninstallMode.isRemovable($0.path) }
    }

    func sections(for query: String) -> [ResultSection] {
        let apps = apps
        let cands = apps.map { RankCandidate(id: $0.id, title: $0.name, alternateTitles: $0.alternateNames, typeWeight: 5) }
        let order = query.isEmpty ? RootRanker.rankEmpty(cands)
            : RootRanker.rank(cands, query: SearchQuery(query), sensitivity: services.settings.data.general.sensitivity)
        let items = order.map { i in
            let app = apps[i]
            return Item(id: app.id, title: app.name, subtitle: (app.path as NSString).deletingLastPathComponent,
                        icon: .file(app.path), accessory: "Uninstall",
                        actions: [Action(title: "Uninstall…") { .push(UninstallMode(app: app)) }],
                        tracksFrecency: false, pushesMode: true)
        }
        return [ResultSection(title: "Applications", items: items)]
    }
}

/// What uninstalling one app will remove, shared by the launcher and the CLI.
struct UninstallPlan {
    let app: AppEntry
    var leftovers: [(url: URL, size: Int64)]
    var bundleSize: Int64
    var cask: String?

    var totalBytes: Int64 { bundleSize + leftovers.reduce(0) { $0 + $1.size } }

    static func make(for app: AppEntry) async -> UninstallPlan {
        let scan = await scan(app)
        return UninstallPlan(app: app, leftovers: scan.leftovers, bundleSize: scan.bundleSize, cask: scan.cask)
    }

    @concurrent
    private static func scan(_ app: AppEntry) async -> (leftovers: [(url: URL, size: Int64)], bundleSize: Int64, cask: String?) {
        let url = URL(fileURLWithPath: app.path)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [(URL, Int64)] = []
        if let bid = app.bundleID {
            let groups = LeftoverScanner.appGroups(of: url)
            found = LeftoverScanner.scan(bundleID: bid, groups: groups, home: home).map { ($0, FileSize.allocated($0)) }
        }
        let cask = app.path.hasPrefix("/Applications/") ? BrewCask.token(forApp: url.deletingPathExtension().lastPathComponent) : nil
        return (found, FileSize.allocated(url), cask)
    }

    /// Quits the app, removes it (brew cask or Trash) and trashes the leftovers.
    func execute() async -> (ok: Bool, message: String) {
        if let bid = app.bundleID, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            running.terminate()
            for _ in 0..<50 where !running.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            if !running.isTerminated { return (false, "\(app.name) is still running. Quit it and try again") }
        }
        var removed = false
        if let cask { removed = await BrewCask.uninstall(cask) }
        if !removed { removed = await Trash.move(URL(fileURLWithPath: app.path)) }
        guard removed else { return (false, "Could not remove \(app.name)") }
        var failed = 0
        for l in leftovers where FileManager.default.fileExists(atPath: l.url.path) {
            if !(await Trash.move(l.url)) { failed += 1 }
        }
        return (true, failed == 0 ? "Uninstalled \(app.name)" : "Uninstalled \(app.name), \(failed) leftovers kept")
    }
}

/// Confirm screen for one app: lists the bundle and its leftovers with sizes.
final class UninstallMode: Mode {
    let title: String?
    let placeholder = "Press ↵ to uninstall, Esc to cancel"
    let tint: NSColor? = Theme.warn
    private let app: AppEntry
    private var plan: UninstallPlan?
    private weak var context: LauncherContext?

    init(app: AppEntry) {
        self.app = app
        title = "Uninstall \(app.name)"
    }

    static func isRemovable(_ path: String) -> Bool {
        !path.hasPrefix("/System/") && !path.hasPrefix("/Library/Apple/")
            && path != Bundle.main.bundlePath
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        context.setLoading(true)
        let app = app
        Task {
            plan = await UninstallPlan.make(for: app)
            context.setLoading(false)
            context.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let size = ByteCountFormatter.string(fromByteCount: plan?.totalBytes ?? 0, countStyle: .file)
        let how = plan?.cask.map { "via brew uninstall --cask \($0)" } ?? "move to Trash"
        let subtitle = plan.map { "\(1 + $0.leftovers.count) items, \(size), \(how)" } ?? "Looking for leftovers…"
        let confirm = Item(id: "uninstall.confirm", title: "Uninstall \(app.name)", subtitle: subtitle,
                           icon: .file(app.path), accessory: nil,
                           actions: [Action(title: "Uninstall", style: .destructive) { [weak self] in
                               guard let self, let plan else { return .stay }
                               context?.setLoading(true)
                               let result = await plan.execute()
                               context?.setLoading(false)
                               return result.ok ? .dismissWithHUD(result.message) : .stayWithHUD(result.message)
                           }], tracksFrecency: false)
        var files = [Item(id: "f.bundle", title: (app.path as NSString).lastPathComponent,
                          subtitle: (app.path as NSString).deletingLastPathComponent, icon: .file(app.path),
                          accessory: plan.map { ByteCountFormatter.string(fromByteCount: $0.bundleSize, countStyle: .file) },
                          actions: revealActions(URL(fileURLWithPath: app.path)), tracksFrecency: false)]
        files += (plan?.leftovers ?? []).map { l in
            Item(id: "f." + l.url.path, title: l.url.lastPathComponent,
                 subtitle: l.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                 icon: .file(l.url.path), accessory: ByteCountFormatter.string(fromByteCount: l.size, countStyle: .file),
                 actions: revealActions(l.url), tracksFrecency: false)
        }
        return [ResultSection(title: nil, items: [confirm]), ResultSection(title: "Will be removed", items: files)]
    }

    private func revealActions(_ url: URL) -> [Action] {
        [Action(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .stay
        }]
    }
}
