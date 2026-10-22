import AppKit

/// KeePassXC sub-mode: unlock, then search entries and paste or copy fields.
/// Action shortcuts follow the Raycast KeePassXC extension.
final class KeePassMode: NSObject, Mode {
    private let session: KeePassSession
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

    init(session: KeePassSession, pins: KeePassPins, sensitivity: Sensitivity, openConfig: @escaping () -> Void) {
        self.session = session
        self.pins = pins
        self.sensitivity = sensitivity
        self.openConfig = openConfig
    }

    var title: String? { "KeePassXC" }

    private var needsPrompt: Bool {
        guard session.state == .locked, session.cliPath != nil, !session.config.database.isEmpty else { return false }
        switch session.config.password {
        case .prompt: return true
        case .keychain: return !CredentialVault.hasPassword(account: session.account)
        case .command, .none: return false
        }
    }

    var isSecureInput: Bool { needsPrompt }

    var placeholder: String {
        if needsPrompt { return "Master password for \((session.config.database as NSString).lastPathComponent)" }
        return session.state == .unlocked ? "Search entries…" : "KeePassXC"
    }

    var accessoryView: NSView? {
        guard session.state == .unlocked else { return nil }
        let folders = KeePassCSV.folders(session.entries)
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

    func didEnter(_ context: LauncherContext) {
        self.context = context
        session.onChange = { [weak self] in
            self?.context?.refreshChrome()
        }
        if session.state == .unlocked {
            Task { await session.refreshIfChanged() }
        } else if !needsPrompt {
            autoUnlock()
        }
    }

    func didExit() { session.onChange = nil }

    /// Unlock without typing: password command, no password, or the Keychain behind Touch ID.
    private func autoUnlock() {
        guard session.state == .locked, session.cliPath != nil, !session.config.database.isEmpty else { return }
        let config = session.config
        Task {
            do {
                switch config.password {
                case .none:
                    try await session.unlock(password: nil)
                case .command:
                    try await session.unlock(password: try await KeePassCLI.passwordFromCommand(config.passwordCommand))
                case .keychain:
                    context?.suppressAutoHide = true
                    let ok = await CredentialVault.authenticate(reason: "unlock your KeePassXC database")
                    context?.suppressAutoHide = false
                    guard ok, let pw = CredentialVault.load(account: session.account) else { throw KeePassError.cancelled }
                    do { try await session.unlock(password: pw) } catch KeePassError.invalidCredentials {
                        CredentialVault.delete(account: session.account) // stale: ask again next time
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

    private func unlock(with password: String) async -> ActionResult {
        guard !password.isEmpty else { return .stay }
        context?.setQuery("")
        do {
            try await session.unlock(password: password)
            if session.config.password == .keychain { _ = CredentialVault.save(password, account: session.account) }
            return .stay
        } catch let e as KeePassError {
            return .stayWithHUD(e.message)
        } catch {
            return .stay
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let config = session.config
        if !config.enabled || config.database.isEmpty {
            return [info("Set up KeePassXC", "Set keepass.enabled and keepass.database in the hop config",
                         symbol: "gearshape", action: Action(title: "Open Config") { [openConfig] in openConfig(); return .dismiss })]
        }
        if session.cliPath == nil { return [info("keepassxc-cli not found", KeePassError.cliNotFound.message, symbol: "exclamationmark.triangle")] }
        switch session.state {
        case .unlocking:
            return [info("Unlocking…", (config.database as NSString).abbreviatingWithTildeInPath, symbol: "lock.open")]
        case .locked:
            let subtitle = session.lastError?.message ?? (config.database as NSString).abbreviatingWithTildeInPath
            if needsPrompt {
                return [info("Unlock Database", subtitle, symbol: "lock.fill", action: Action(title: "Unlock") { [weak self] in
                    guard let self else { return .stay }
                    return await unlock(with: context?.query ?? "")
                })]
            }
            return [info("Unlock Database", subtitle, symbol: "lock.fill", action: Action(title: "Unlock") { [weak self] in
                self?.autoUnlock()
                return .stay
            })]
        case .unlocked:
            return entrySections(query)
        }
    }

    private func info(_ title: String, _ subtitle: String, symbol: String, action: Action? = nil) -> ResultSection {
        ResultSection(title: nil, items: [Item(id: "kp.info", title: title, subtitle: subtitle, icon: .symbol(symbol),
                                               actions: action.map { [$0] } ?? [], tracksFrecency: false)])
    }

    private func entrySections(_ query: String) -> [ResultSection] {
        session.touch()
        let pinned = pins.ids(for: session.account)
        var list = session.entries.filter { folder.isEmpty || $0.group == folder || $0.group.hasPrefix(folder + "/") }
        if !query.isEmpty {
            let cands = list.map { e in
                RankCandidate(id: e.id, title: e.title, alternateTitles: [e.username, URL(string: e.url)?.host ?? ""].filter { !$0.isEmpty },
                              keywords: [e.group, e.url].filter { !$0.isEmpty }, typeWeight: 1)
            }
            list = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { list[$0] }
        }
        let favorites = list.filter { pinned.contains($0.id) }
        let others = list.filter { !pinned.contains($0.id) }
        var sections: [ResultSection] = []
        if !favorites.isEmpty { sections.append(ResultSection(title: "Favorites", items: favorites.map { item($0, pinned: true) })) }
        sections.append(ResultSection(title: favorites.isEmpty ? nil : "Entries", items: others.map { item($0, pinned: false) }))
        return sections
    }

    private func item(_ e: KeePassEntry, pinned: Bool) -> Item {
        var badges: [String] = []
        if !e.totp.isEmpty { badges.append("TOTP") }
        if !e.group.isEmpty { badges.append(e.group) }
        return Item(id: "kp." + e.id, title: e.title, subtitle: e.username,
                    icon: .symbol(pinned ? "star.fill" : "key.fill", tint: pinned ? .systemYellow : .secondaryLabelColor),
                    accessory: badges.joined(separator: " · "), actions: actions(e, pinned: pinned), tracksFrecency: false)
    }

    private func actions(_ e: KeePassEntry, pinned: Bool) -> [Action] {
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
                guard let url = URL(string: value(e.url)), url.scheme != nil else { return .stayWithHUD("No URL set") }
                NSWorkspace.shared.open(url)
                return .dismiss
            },
            Action(title: pinned ? "Unpin Entry" : "Pin Entry", shortcut: .cmd("s")) { [weak self] in
                guard let self else { return .stay }
                pins.toggle(e.id, for: session.account)
                return .reload
            },
            Action(title: "Lock Database", shortcut: .cmd("l")) { [weak self] in
                self?.session.lock()
                return .stayWithHUD("Database locked")
            },
        ]
    }

    private func paste(_ title: String, _ key: KeyCombo, concealed: Bool, _ get: @escaping () -> String?) -> Action {
        Action(title: title, shortcut: key) { [weak self] in
            guard let text = get() else { return .stayWithHUD("Nothing to paste") }
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
            guard let text = get() else { return .stayWithHUD("Nothing to copy") }
            Pasteboard.copy(text, concealed: concealed)
            if concealed {
                Pasteboard.clearLater(after: 30)
                return .dismissWithHUD("Copied, clears in 30 s")
            }
            return .dismissWithHUD("Copied")
        }
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
        guard services.settings.data.keepass.enabled, let make = services.keepassMode else { return [] }
        return [Item(id: "keepass.search", title: "KeePassXC", subtitle: "Search passwords (or type “kp ”)",
                     icon: .symbol("key.horizontal.fill"), accessory: "Command",
                     actions: [Action(title: "Search Entries") { .push(make()) }], pushesMode: true)]
    }
}
