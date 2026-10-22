import AppKit

/// "Are you sure?" screen: optional detail rows, then a confirm and a cancel item.
final class ConfirmMode: Mode {
    let title: String?
    let placeholder: String
    private var message: String
    private var details: [Item] = []
    private let confirmTitle: String
    private let symbol: String
    private let prepare: ((ConfirmMode) async -> Void)?
    private let confirm: () async -> ActionResult
    private weak var context: LauncherContext?
    private var ready: Bool

    /// `prepare` runs once on entry (e.g. to count files) and may update the message and details.
    init(title: String, message: String, confirmTitle: String, symbol: String,
         prepare: ((ConfirmMode) async -> Void)? = nil, confirm: @escaping () async -> ActionResult) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.symbol = symbol
        self.prepare = prepare
        self.confirm = confirm
        placeholder = "Press ↵ to confirm, Esc to cancel"
        ready = prepare == nil
    }

    func update(message: String, details: [Item] = []) {
        self.message = message
        self.details = details
        context?.reload()
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        guard let prepare else { return }
        context.setLoading(true)
        Task {
            await prepare(self)
            ready = true
            context.setLoading(false)
            context.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        let confirmItem = Item(
            id: "confirm", title: confirmTitle, subtitle: message,
            icon: .symbol(symbol, tint: .systemRed), accessory: ready ? nil : "Preparing…",
            actions: [Action(title: confirmTitle, style: .destructive) { [weak self] in
                guard let self, ready else { return .stay }
                return await confirm()
            }], tracksFrecency: false)
        let cancel = Item(id: "cancel", title: "Cancel", icon: .symbol("xmark.circle"),
                          actions: [Action(title: "Cancel") { .pop }], tracksFrecency: false)
        var sections = [ResultSection(title: nil, items: [confirmItem, cancel])]
        if !details.isEmpty { sections.append(ResultSection(title: "Details", items: details)) }
        return sections
    }
}
