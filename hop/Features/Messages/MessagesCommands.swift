import AppKit

/// Root commands for codes received in Messages.
enum MessagesCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.messages
        guard config.enabled else { return [] }
        return [
            Item(id: "messages.codes", title: "Messages Codes", subtitle: "Verification codes from SMS and iMessage",
                 aliases: ["otp", "2fa", "sms code"], icon: .tile("message.fill", Palette.messages), accessory: "Command",
                 actions: [Action(title: "Show Codes", symbol: "message") {
                     .push(MessageCodesMode(days: config.days, sensitivity: services.settings.data.general.sensitivity))
                 }], pushesMode: true),
            Item(id: "messages.pasteCode", title: "Paste Latest Code",
                 subtitle: "The newest code from the last \(config.latestMinutes) minutes",
                 aliases: ["otp", "2fa"], icon: .tile("text.badge.checkmark", Palette.messages), accessory: "Command",
                 actions: [Action(title: "Paste Latest Code", symbol: "doc.on.clipboard") {
                     await pasteLatest(within: config.latestMinutes, hideLauncher: services.hideLauncher)
                 }]),
        ]
    }

    static func pasteLatest(within minutes: Int, hideLauncher: (() -> Void)?) async -> ActionResult {
        switch await MessageCodes.recent(since: Date().addingTimeInterval(-Double(minutes) * 60)) {
        case .failure(.noAccess):
            NSWorkspace.shared.open(Permission.fullDiskAccess.settingsURL)
            return .failWithHUD("Allow hop in Full Disk Access to read Messages")
        case .failure(.unreadable(let message)):
            return .failWithHUD("Could not read Messages: \(message)")
        case .success(let codes):
            guard let latest = codes.first else { return .warnWithHUD("No code in the last \(minutes) minutes") }
            hideLauncher?()
            await MessageCodesMode.paste(latest)
            return .stay
        }
    }
}

/// Sub-mode listing recent codes; ↵ pastes one.
final class MessageCodesMode: Mode {
    let title: String? = "Messages"
    let tint: NSColor? = Palette.messages
    let placeholder = "Search codes by sender or text…"
    private let days: Int
    private let sensitivity: Sensitivity
    private var result: Result<[MessageCode], MessageCodes.Failure>?
    private weak var context: LauncherContext?

    init(days: Int, sensitivity: Sensitivity) {
        self.days = days
        self.sensitivity = sensitivity
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        Task {
            context.setLoading(true)
            result = await MessageCodes.recent(since: Date().addingTimeInterval(-Double(days) * 86400))
            context.setLoading(false)
            context.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        switch result {
        case nil:
            return []
        case .failure(.noAccess):
            return [ResultSection(title: nil, items: [Item(
                id: "messages.access", title: "Allow Full Disk Access",
                subtitle: "hop reads codes from ~/Library/Messages, which macOS protects",
                icon: .tile("externaldrive.fill", Theme.warn), accessory: "System Settings",
                actions: [Action(title: "Open System Settings", symbol: "gearshape") {
                    NSWorkspace.shared.open(Permission.fullDiskAccess.settingsURL)
                    return .dismiss
                }], tracksFrecency: false)])]
        case .failure(.unreadable(let message)):
            return [ResultSection(title: nil, items: [Item(
                id: "messages.error", title: "Could not read Messages", subtitle: message,
                icon: .symbol("exclamationmark.triangle"), actions: [], tracksFrecency: false)])]
        case .success(let codes):
            var list = codes
            if !query.isEmpty {
                let cands = list.map { RankCandidate(id: String($0.id), title: $0.sender, alternateTitles: [$0.code], subtitle: $0.text, typeWeight: 1) }
                list = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { list[$0] }
            }
            guard !codes.isEmpty else {
                return [ResultSection(title: nil, items: [Item(
                    id: "messages.none", title: "No codes in the last \(days) days",
                    icon: .symbol("message"), actions: [], tracksFrecency: false)])]
            }
            let now = Date()
            return [ResultSection(title: "Codes", items: list.map { item($0, now: now) })]
        }
    }

    private func item(_ c: MessageCode, now: Date) -> Item {
        let preview = c.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return Item(id: "messages.\(c.id)", title: c.code, subtitle: "\(c.sender) · \(preview)",
                    icon: .tile("message.fill", Palette.messages), accessory: NoteStore.shortAge(c.date, now: now),
                    actions: [
                        Action(title: "Paste Code") { [weak self] in
                            self?.context?.dismiss()
                            await Self.paste(c)
                            return .stay
                        },
                        Action(title: "Copy Code", shortcut: .cmd("c")) {
                            Pasteboard.copy(c.code, concealed: true)
                            Pasteboard.clearLater(after: 60)
                            return .dismissWithHUD("Copied \(c.code), clears in 60 s")
                        },
                        Action(title: "Copy Message", shortcut: .cmd("c", .shift)) {
                            Pasteboard.copy(c.text)
                            return .dismissWithHUD("Copied message")
                        },
                        Action(title: "Open Messages", shortcut: .cmd("o")) {
                            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
                                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                            }
                            return .dismiss
                        },
                    ], tracksFrecency: false, monoTitle: true)
    }

    /// Pastes into the frontmost app; kept out of clipboard history.
    static func paste(_ c: MessageCode) async {
        if await Pasteboard.paste(c.code, concealed: true) {
            HUD.shared.show("Pasted \(c.code) from \(c.sender)")
        } else {
            Pasteboard.clearLater(after: 60)
            HUD.shared.show("Copied \(c.code). Allow hop in Accessibility to paste")
        }
    }
}
