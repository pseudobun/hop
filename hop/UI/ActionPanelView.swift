import AppKit

/// ⌘K list of the selected item's actions, overlaid bottom-right of the launcher.
final class ActionPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var glide = SelectionGlide(table: table)
    private(set) var actions: [Action] = []
    var onPerform: ((Action) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 0.5
        shadow = NSShadow()

        let column = NSTableColumn(identifier: .init("action"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat { CGFloat(min(actions.count, 8)) * 32 + 12 }

    func show(_ actions: [Action]) {
        self.actions = actions
        table.reloadData()
        if !actions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        glide.sync(animated: false)
    }

    /// Returns true when the key was handled.
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76:
            let row = table.selectedRow
            if row >= 0 { onPerform?(actions[row]) }
            return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !actions.isEmpty else { return }
        let next = max(0, min(actions.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
        glide.sync(animated: true)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        if row >= 0 { onPerform?(actions[row]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView.reused(by: tableView)
        v.drawsSelection = false
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = actions[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: a.resolvedSymbol, accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) } ?? NSImage())
        icon.contentTintColor = a.style == .destructive ? Theme.destructive : Theme.mutedForeground
        let title = NSTextField(labelWithString: a.title)
        title.font = Theme.sans(13)
        title.textColor = a.style == .destructive ? Theme.destructive : Theme.foreground
        let key = NSTextField(labelWithString: row == 0 ? "↵" : (a.shortcut?.display ?? ""))
        key.font = Theme.mono(11, 500)
        key.textColor = Theme.mutedForeground
        for v in [icon, title, key] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            key.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            key.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
        ])
        return cell
    }
}
