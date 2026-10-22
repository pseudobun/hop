import AppKit

/// ⌘K list of the selected item's actions, overlaid bottom-right of the launcher.
final class ActionPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var actions: [Action] = []
    var onPerform: ((Action) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
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
    }

    @objc private func clicked() {
        let row = table.clickedRow
        if row >= 0 { onPerform?(actions[row]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = actions[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: a.title)
        title.font = .systemFont(ofSize: 13)
        if a.style == .destructive { title.textColor = .systemRed }
        let key = NSTextField(labelWithString: row == 0 ? "↵" : (a.shortcut?.display ?? ""))
        key.font = .systemFont(ofSize: 12)
        key.textColor = .secondaryLabelColor
        for v in [title, key] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            key.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            key.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
        ])
        return cell
    }
}
