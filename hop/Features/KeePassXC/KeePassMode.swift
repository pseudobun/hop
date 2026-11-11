import AppKit
import os

/// KeePassXC sub-mode: unlock, then search entries and paste or copy fields.
/// Works on one database or on all unlocked ones; ⌘D switches. Action shortcuts
/// follow the Raycast KeePassXC extension.
final class KeePassMode: NSObject, Mode {
    private let manager: KeePassManager
    private let pins: KeePassPins
    private let sensitivity: Sensitivity
    private let openConfig: () -> Void
    private weak var context: LauncherContext?
    private var folder = ""
    private lazy var folderPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        p.target = self
        p.action = #selector(folderChanged)
        return p
    }()

    init(manager: KeePassManager, pins: KeePassPins, sensitivity: Sensitivity, openConfig: @escaping () -> Void) {
        self.manager = manager
        self.pins = pins
        self.sensitivity = sensitivity
        self.openConfig = openConfig
    }

    // MARK: - Selection

    /// Session for a single selected database; nil when "All Databases" is selected.
    private var session: KeePassSession? {
        if case .database(let path) = manager.selection { return manager.session(path) }
        return nil
    }

    private var allSessions: [KeePassSession] { manager.databases.map { manager.session($0.expandedPath) } }

    var title: String? {
        switch manager.selection {
        case .all: "KeePassXC · All"
        case .database: manager.databases.count > 1 ? "KeePassXC · \(session?.database.label ?? "")" : "KeePassXC"
        }
    }

    var tint: NSColor? { Palette.keepass }

    private func needsPrompt(_ s: KeePassSession) -> Bool {
        guard s.state == .locked, s.cliPath != nil else { return false }
        switch s.database.password {
        case .prompt: return true
        case .keychain: return !CredentialVault.hasPassword(account: s.account)
        case .command, .none: return false
        }
    }

    var isSecureInput: Bool { session.map(needsPrompt) ?? false }

    var placeholder: String {
        if let s = session, needsPrompt(s) { return "Master password for \(s.database.label)" }
        if manager.selection == .all { return "Search all unlocked databases…" }
        return session?.state == .unlocked ? "Search entries…" : "KeePassXC"
    }

    private var unlockedEntries: [(entry: KeePassEntry, session: KeePassSession)] {
        let sessions = session.map { [$0] } ?? allSessions
        return sessions.filter { $0.state == .unlocked }.flatMap { s in s.entries.map { (entry: $0, session: s) } }
    }

    var accessoryView: NSView? {
        let folders = KeePassCSV.folders(unlockedEntries.map(\.entry))
        guard !folders.isEmpty else { return nil }
        folderPopup.removeAllItems()
        folderPopup.addItem(withTitle: "All Folders")
        folderPopup.addItems(withTitles: folders)
        folderPopup.selectItem(withTitle: folder.isEmpty ? "All Folders" : folder)
        return folderPopup
    }

    @objc private func folderChanged() {
        folder = folderPopup.indexOfSelectedItem <= 0 ? "" : (folderPopup.titleOfSelectedItem ?? "")
        context?.reload()
    }

    /// Called by the picker after the selection changed.
    func selectionChanged() {
        folder = ""
        context?.refreshChrome()
        startUnlocking()
    }

    // MARK: - Lifecycle

    func didEnter(_ context: LauncherContext) {
        self.context = context
        manager.onChange = { [weak self] in self?.context?.refreshChrome() }
        FaviconCache.shared.onUpdate = { [weak self] in self?.context?.reload() }
        startUnlocking()
    }

    func didExit() {
        manager.onChange = nil
        FaviconCache.shared.onUpdate = nil
    }

    private func startUnlocking() {
        if let s = session {
            if s.state == .unlocked { Task { await s.refreshIfChanged() } } else if !needsPrompt(s) { autoUnlock(s) }
        } else {
            // All: refresh unlocked ones and open the ones that need no typing or Touch ID.
            for s in allSessions {
                if s.state == .unlocked { Task { await s.refreshIfChanged() } }
                else if s.database.password == .command || s.database.password == .none { autoUnlock(s) }
            }
        }
    }

    /// Unlock without typing: password command, no password, or the Keychain behind Touch ID.
    private func autoUnlock(_ s: KeePassSession) {
        guard s.state == .locked, s.cliPath != nil else { return }
        let db = s.database
        Task {
            do {
                switch db.password {
                case .none:
                    try await s.unlock(password: nil)
                case .command:
                    try await s.unlock(password: try await KeePassCLI.passwordFromCommand(db.passwordCommand))
                case .keychain:
                    guard CredentialVault.hasPassword(account: s.account) else { return }
                    context?.suppressAutoHide = true
                    let ok = await CredentialVault.authenticate(reason: "unlock \(db.label)")
                    context?.suppressAutoHide = false
                    guard ok, let pw = CredentialVault.load(account: s.account) else { throw KeePassError.cancelled }
                    do { try await s.unlock(password: pw) } catch KeePassError.invalidCredentials {
                        CredentialVault.delete(account: s.account) // stale: ask again next time
                        throw KeePassError.invalidCredentials
                    }
                case .prompt:
                    return
                }
            } catch {
                context?.refreshChrome()
            }
        }
    }

    /// One Touch ID prompt for every database whose password is in the Keychain.
    private func unlockAllFromKeychain(_ sessions: [KeePassSession]) async {
        context?.suppressAutoHide = true
        let ok = await CredentialVault.authenticate(reason: "unlock your KeePassXC databases")
        context?.suppressAutoHide = false
        guard ok else { return }
        for s in sessions {
            guard let pw = CredentialVault.load(account: s.account) else { continue }
            try? await s.unlock(password: pw)
        }
    }

    private func unlock(_ s: KeePassSession, with password: String) async -> ActionResult {
        guard !password.isEmpty else { return .stay }
        context?.setQuery("")
        do {
            try await s.unlock(password: password)
            if s.database.password == .keychain {
                let status = CredentialVault.save(password, account: s.account)
                if status != errSecSuccess {
                    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                    Log.app.error("keepass: Keychain save failed: \(status) \(reason, privacy: .public)")
                    return .warnWithHUD("Unlocked, but the Keychain did not keep the password: \(reason)")
                }
            }
            return .stay
        } catch let e as KeePassError {
            return .failWithHUD(e.message)
        } catch {
            return .stay
        }
    }

    // MARK: - Sections

    private var switchAction: Action {
        Action(title: "Switch Database", shortcut: .cmd("d")) { [weak self] in
            guard let self else { return .stay }
            return .push(KeePassDatabasePicker(manager: manager, sensitivity: sensitivity) { [weak self] in self?.selectionChanged() })
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let k = manager.databases
        guard manager.databases.first != nil, !k.isEmpty else {
            return [info("Set up KeePassXC", "Add your .kdbx files to keepass.databases in the hop config",
                         symbol: "gearshape", actions: [Action(title: "Open Config") { [openConfig] in openConfig(); return .dismiss }])]
        }
        if manager.databases.first.map({ manager.session($0.expandedPath).cliPath }) == nil {
            return [info("keepassxc-cli not found", KeePassError.cliNotFound.message, symbol: "exclamationmark.triangle")]
        }
        if let s = session {
            switch s.state {
            case .unlocking:
                return [info("Unlocking \(s.database.label)…", (s.path as NSString).abbreviatingWithTildeInPath, symbol: "lock.open")]
            case .locked:
                return [lockedRow(s)]
            case .unlocked:
                return entrySections(query)
            }
        }
        // All databases: unlock rows for locked ones, then entries from the unlocked ones.
        let locked = allSessions.filter { $0.state != .unlocked }
        var sections: [ResultSection] = []
        if !locked.isEmpty {
            var rows = locked.flatMap { lockedRow($0).items }
            let viaKeychain = locked.filter { $0.state == .locked && $0.database.password == .keychain && CredentialVault.hasPassword(account: $0.account) }
            if viaKeychain.count > 1 {
                rows.insert(Item(id: "kp.unlockAll", title: "Unlock All", subtitle: viaKeychain.map(\.database.label).joined(separator: ", "),
                                 icon: .tile("lock.open.fill", Palette.keepass),
                                 actions: [Action(title: "Unlock with Touch ID") { [weak self] in
                                     await self?.unlockAllFromKeychain(viaKeychain)
                                     return .stay
                                 }], tracksFrecency: false), at: 0)
            }
            sections.append(ResultSection(title: "Locked", items: rows))
        }
        return sections + entrySections(query)
    }

    private func lockedRow(_ s: KeePassSession) -> ResultSection {
        let subtitle = s.lastError?.message ?? (s.path as NSString).abbreviatingWithTildeInPath
        let title = s.state == .unlocking ? "Unlocking \(s.database.label)…" : "Unlock \(s.database.label)"
        if needsPrompt(s) && session != nil {
            return info(title, subtitle, symbol: "lock.fill", actions: [Action(title: "Unlock") { [weak self] in
                guard let self else { return .stay }
                return await unlock(s, with: context?.query ?? "")
            }, switchAction])
        }
        if needsPrompt(s) {
            // In "All", typing a password needs that database selected.
            return info(title, "Select it to type the password", symbol: "lock.fill", actions: [Action(title: "Select Database") { [weak self] in
                self?.manager.selection = .database(s.path)
                self?.selectionChanged()
                return .stay
            }, switchAction])
        }
        return info(title, subtitle, symbol: "lock.fill", actions: [Action(title: "Unlock") { [weak self] in
            self?.autoUnlock(s)
            return .stay
        }, switchAction])
    }

    private func info(_ title: String, _ subtitle: String, symbol: String, actions: [Action] = []) -> ResultSection {
        ResultSection(title: nil, items: [Item(id: "kp.info.\(title)", title: title, subtitle: subtitle, icon: .tile(symbol, Palette.keepass),
                                               actions: actions, tracksFrecency: false,
                                               chip: symbol == "lock.fill" ? Chip(text: "Locked", tone: .warn) : nil)])
    }

    private func entrySections(_ query: String) -> [ResultSection] {
        let showDatabase = session == nil && manager.databases.count > 1
        var list = unlockedEntries.filter { folder.isEmpty || $0.entry.group == folder || $0.entry.group.hasPrefix(folder + "/") }
        // Once per database, not once per entry: each touch replaces the auto-lock task.
        var touched = Set<ObjectIdentifier>()
        for pair in list where touched.insert(ObjectIdentifier(pair.session)).inserted { pair.session.touch() }
        if !query.isEmpty {
            let cands = list.map { pair in
                let e = pair.entry
                return RankCandidate(id: e.id, title: e.title,
                                     alternateTitles: [e.username, URL(string: e.url)?.host ?? ""].filter { !$0.isEmpty },
                                     keywords: [e.group, e.url, pair.session.database.label].filter { !$0.isEmpty }, typeWeight: 1)
            }
            list = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { list[$0] }
        }
        var pinSets: [ObjectIdentifier: Set<String>] = [:]
        let isPinned = { [pins] (pair: (entry: KeePassEntry, session: KeePassSession)) -> Bool in
            let key = ObjectIdentifier(pair.session)
            if pinSets[key] == nil { pinSets[key] = pins.ids(for: pair.session.account) }
            return pinSets[key]!.contains(pair.entry.id)
        }
        let favorites = list.filter(isPinned)
        let others = list.filter { !isPinned($0) }
        var sections: [ResultSection] = []
        if !favorites.isEmpty {
            sections.append(ResultSection(title: "Favorites", items: favorites.map { item($0.entry, $0.session, pinned: true, showDatabase) }))
        }
        sections.append(ResultSection(title: favorites.isEmpty ? nil : "Entries",
                                      items: others.map { item($0.entry, $0.session, pinned: false, showDatabase) }))
        return sections
    }

    private func item(_ e: KeePassEntry, _ s: KeePassSession, pinned: Bool, _ showDatabase: Bool) -> Item {
        var badges: [String] = []
        if pinned { badges.append("★") }
        if !e.totp.isEmpty { badges.append("TOTP") }
        if !e.group.isEmpty { badges.append(e.group) }
        if showDatabase { badges.append(s.database.label) }
        return Item(id: "kp.\(s.path).\(e.id)", title: e.title, subtitle: e.username, icon: icon(for: e),
                    accessory: badges.joined(separator: " · "), actions: actions(e, s, pinned: pinned), tracksFrecency: false)
    }

    private func icon(for e: KeePassEntry) -> ItemIcon {
        if manager.databases.isEmpty == false, (session?.keepass ?? allSessions.first?.keepass)?.favicons ?? true,
           let host = FaviconCache.host(of: e.url), let img = FaviconCache.shared.icon(for: host) {
            return .image(img)
        }
        return .tile("key.fill", Palette.keepass)
    }

    private func actions(_ e: KeePassEntry, _ s: KeePassSession, pinned: Bool) -> [Action] {
        let value: (String) -> String = { KeePassPlaceholders.resolve($0, e) }
        let totp: () -> String? = { e.totp.isEmpty ? nil : try? TOTP.code(e.totp) }
        return [
            paste("Paste Password", .ret(), concealed: true) { e.password.isEmpty ? nil : value(e.password) },
            paste("Paste Username", .ret(.shift), concealed: false) { e.username.isEmpty ? nil : value(e.username) },
            paste("Paste TOTP", .ret(.option), concealed: true, totp),
            paste("Paste URL", .ret(.control), concealed: false) { e.url.isEmpty ? nil : value(e.url) },
            copy("Copy Password", .cmd("g"), concealed: true) { e.password.isEmpty ? nil : value(e.password) },
            copy("Copy Username", .cmd("b"), concealed: false) { e.username.isEmpty ? nil : value(e.username) },
            copy("Copy TOTP", .cmd("t"), concealed: true, totp),
            copy("Copy URL", .cmd("u"), concealed: false) { e.url.isEmpty ? nil : value(e.url) },
            Action(title: "Open URL", shortcut: .cmd("u", .shift)) {
                guard let url = URL(string: value(e.url)), url.scheme != nil else { return .warnWithHUD("No URL set") }
                NSWorkspace.shared.open(url)
                return .dismiss
            },
            Action(title: pinned ? "Unpin Entry" : "Pin Entry", shortcut: .cmd("s")) { [weak self] in
                self?.pins.toggle(e.id, for: s.account)
                return .reload
            },
            switchAction,
            Action(title: "Lock \(s.database.label)", shortcut: .cmd("l")) {
                s.lock()
                return .stayWithHUD("\(s.database.label) locked")
            },
        ]
    }

    private func paste(_ title: String, _ key: KeyCombo, concealed: Bool, _ get: @escaping () -> String?) -> Action {
        Action(title: title, shortcut: key) { [weak self] in
            guard let text = get() else { return .warnWithHUD("Nothing to paste") }
            self?.context?.dismiss()
            let pasted = await Pasteboard.paste(text, concealed: concealed)
            if !pasted {
                if concealed { Pasteboard.clearLater(after: 30) }
                HUD.shared.show("Copied. Allow hop in Accessibility to paste")
            }
            return .stay
        }
    }

    private func copy(_ title: String, _ key: KeyCombo, concealed: Bool, _ get: @escaping () -> String?) -> Action {
        Action(title: title, shortcut: key) {
            guard let text = get() else { return .warnWithHUD("Nothing to copy") }
            Pasteboard.copy(text, concealed: concealed)
            if concealed {
                Pasteboard.clearLater(after: 30)
                return .dismissWithHUD("Copied, clears in 30 s")
            }
            return .dismissWithHUD("Copied")
        }
    }
}

/// ⌘D: pick a database, or "All Databases".
final class KeePassDatabasePicker: Mode {
    let title: String? = "KeePassXC · Databases"
    let tint: NSColor? = Palette.keepass
    let placeholder = "Switch database…"
    private let manager: KeePassManager
    private let sensitivity: Sensitivity
    private let onPick: () -> Void

    init(manager: KeePassManager, sensitivity: Sensitivity, onPick: @escaping () -> Void) {
        self.manager = manager
        self.sensitivity = sensitivity
        self.onPick = onPick
    }

    func sections(for query: String) -> [ResultSection] {
        var dbs = manager.databases
        if !query.isEmpty {
            let cands = dbs.map { RankCandidate(id: $0.expandedPath, title: $0.label, alternateTitles: [$0.path], typeWeight: 1) }
            dbs = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { dbs[$0] }
        }
        let current = manager.selection
        var items = dbs.map { db -> Item in
            let s = manager.session(db.expandedPath)
            let state = switch s.state {
            case .unlocked: "Unlocked · \(s.entries.count) entries"
            case .unlocking: "Unlocking…"
            case .locked: "Locked"
            }
            return Item(id: "db.\(db.expandedPath)", title: db.label, subtitle: (db.path as NSString).abbreviatingWithTildeInPath,
                        icon: .tile(s.state == .unlocked ? "lock.open.fill" : "lock.fill", Palette.keepass),
                        accessory: (current == .database(db.expandedPath) ? "✓ " : "") + state,
                        actions: [
                            Action(title: "Use Database") { [weak self] in
                                self?.manager.selection = .database(db.expandedPath)
                                self?.onPick()
                                return .pop
                            },
                            Action(title: "Lock", shortcut: .cmd("l")) { s.lock(); return .reload },
                        ], tracksFrecency: false)
        }
        if manager.databases.count > 1 && query.isEmpty {
            items.insert(Item(id: "db.all", title: "All Databases", subtitle: "Search every unlocked database",
                              icon: .tile("square.stack.3d.up.fill", Palette.keepass), accessory: current == .all ? "✓" : nil,
                              actions: [Action(title: "Use All Databases") { [weak self] in
                                  self?.manager.selection = .all
                                  self?.onPick()
                                  return .pop
                              }], tracksFrecency: false), at: 0)
        }
        return [ResultSection(title: "Databases", items: items)]
    }
}

/// Pinned entry ids per database, in `keepass-pins.json`.
final class KeePassPins {
    private let store = JSONStore<[String: [String]]>(url: AppPaths.file("keepass-pins.json"))
    private var data: [String: [String]]

    init() { data = store.load() ?? [:] }

    func ids(for db: String) -> Set<String> { Set(data[db] ?? []) }

    func toggle(_ id: String, for db: String) {
        var list = data[db] ?? []
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        data[db] = list
        store.save(data)
    }
}

enum KeePassCommands {
    static func items(_ services: Services) -> [Item] {
        guard let make = services.keepassMode, let manager = services.keepass else { return [] }
        let k = services.settings.data.keepass
        let dbs = k.allDatabases
        let ready = k.enabled && !dbs.isEmpty
        var items = [Item(id: "keepass.search", title: "KeePassXC",
                          subtitle: ready ? "Search passwords (or type “kp ”)" : "Set up keepass in ~/.config/hop/config.json5",
                          icon: .tile("key.horizontal.fill", Palette.keepass), accessory: "Command",
                          actions: [Action(title: "Search Entries") { .push(make()) }], pushesMode: true)]
        guard ready, dbs.count > 1 else { return items }
        // One root command per database for quick switching.
        items += dbs.map { db in
            Item(id: "keepass.db.\(db.expandedPath)", title: "\(db.label) Passwords", subtitle: "KeePassXC · \(db.label)",
                 icon: .tile("key.horizontal.fill", Palette.keepass), accessory: "Command",
                 actions: [Action(title: "Search \(db.label)") {
                     manager.selection = .database(db.expandedPath)
                     return .push(make())
                 }], pushesMode: true)
        }
        return items
    }
}
