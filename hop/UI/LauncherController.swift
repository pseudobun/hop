import AppKit

/// Owns the panel, the mode stack and the result list.
final class LauncherController: NSObject, LauncherContext, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSWindowDelegate {
    private enum Row {
        case header(String)
        case item(Item)
    }

    let panel = LauncherPanel()
    private let root: Mode
    private var modes: [Mode]
    private var current: Mode { modes.last! }
    var onItemPerformed: ((Item, Int) -> Void)?
    var popToRootSeconds: () -> Int = { 90 }

    private var rows: [Row] = []
    private var lastHidden = Date.distantPast
    private var loadingCount = 0
    private var autoHideSuppression = 0

    // Views
    private let searchField = NSTextField()
    private let secureField = NSSecureTextField()
    private let modePill = NSTextField(labelWithString: "")
    private let accessoryHolder = NSStackView()
    private let spinner = NSProgressIndicator()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footerTitle = NSTextField(labelWithString: "")
    private let footerActions = NSTextField(labelWithString: "Actions  ⌘K")
    private let emptyLabel = NSTextField(labelWithString: "No results")
    private let actionPanel = ActionPanelView()
    private var actionPanelHeight: NSLayoutConstraint!

    init(root: Mode) {
        self.root = root
        modes = [root]
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
    }

    // MARK: - LauncherContext

    var query: String { activeField.stringValue }

    var suppressAutoHide: Bool {
        get { autoHideSuppression > 0 }
        set { autoHideSuppression = max(0, autoHideSuppression + (newValue ? 1 : -1)) }
    }

    func reload() { refresh(keepSelection: true) }

    func refreshChrome() {
        // Keep the typed query unless the field switches between plain and secure.
        let keep = searchField.isHidden == current.isSecureInput ? query : ""
        enterCurrentMode(query: keep)
        refresh()
        activeField.currentEditor()?.moveToEndOfDocument(nil)
    }

    func setQuery(_ query: String) {
        activeField.stringValue = query
        refresh()
        activeField.currentEditor()?.moveToEndOfDocument(nil)
    }

    func push(_ mode: Mode) {
        closeActionPanel()
        modes.append(mode)
        enterCurrentMode(query: "")
        mode.didEnter(self)
        refresh()
    }

    func pop() {
        guard modes.count > 1 else { return }
        closeActionPanel()
        modes.removeLast().didExit()
        enterCurrentMode(query: "")
        refresh()
    }

    func dismiss() { hide() }

    func popToRoot() {
        closeActionPanel()
        while modes.count > 1 { modes.removeLast().didExit() }
        enterCurrentMode(query: "")
        refresh()
    }

    func showHUD(_ text: String) { HUD.shared.show(text) }

    func setLoading(_ loading: Bool) {
        loadingCount = max(0, loadingCount + (loading ? 1 : -1))
        if loadingCount > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(query initial: String? = nil) {
        if Date().timeIntervalSince(lastHidden) > Double(popToRootSeconds()) {
            while modes.count > 1 { modes.removeLast().didExit() }
            enterCurrentMode(query: "")
            select(nil)
        }
        if let initial { activeField.stringValue = initial }
        refresh()
        panel.positionOnMouseScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(activeField)
        activeField.currentEditor()?.selectAll(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        closeActionPanel()
        panel.orderOut(nil)
        lastHidden = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoHide { hide() }
    }

    // MARK: - Query

    private var activeField: NSTextField { current.isSecureInput ? secureField : searchField }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func enterCurrentMode(query: String) {
        let secure = current.isSecureInput
        searchField.isHidden = secure
        secureField.isHidden = !secure
        activeField.stringValue = query
        activeField.placeholderString = current.placeholder
        modePill.stringValue = current.title.map { "\u{2002}\($0)\u{2002}" } ?? ""
        let tone = current.tint ?? Theme.info
        modePill.layer?.backgroundColor = tone.withAlphaComponent(0.15).cgColor
        modePill.textColor = tone
        modePill.isHidden = current.title == nil
        accessoryHolder.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let accessory = current.accessoryView { accessoryHolder.addArrangedSubview(accessory) }
        panel.makeFirstResponder(activeField)
    }

    private func refresh(keepSelection: Bool = false) {
        let previousID = keepSelection ? selectedItem?.id : nil
        let sections = current.sections(for: query)
        rows = []
        for s in sections where !s.items.isEmpty {
            if let t = s.title { rows.append(.header(t)) }
            rows.append(contentsOf: s.items.map(Row.item))
        }
        table.reloadData()
        var target = firstItemRow(from: 0, step: 1)
        if let previousID, let i = rows.firstIndex(where: { if case .item(let it) = $0 { it.id == previousID } else { false } }) {
            target = i
        }
        select(target)
        emptyLabel.isHidden = !rows.isEmpty || query.isEmpty && current === root
    }

    // MARK: - Selection

    private var selectedItem: Item? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .item(let item) = rows[r] else { return nil }
        return item
    }

    private func firstItemRow(from start: Int, step: Int) -> Int? {
        var i = start
        while i >= 0 && i < rows.count {
            if case .item = rows[i] { return i }
            i += step
        }
        return nil
    }

    private func select(_ row: Int?) {
        guard let row else {
            table.deselectAll(nil)
            updateFooter()
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        // Keep a section header visible above the first item.
        table.scrollRowToVisible(row > 0 && firstItemRow(from: 0, step: 1) == row ? 0 : row)
        updateFooter()
    }

    private func move(_ step: Int) {
        let start = table.selectedRow < 0 ? (step > 0 ? 0 : rows.count - 1) : table.selectedRow + step
        if let next = firstItemRow(from: start, step: step) { select(next) }
    }

    private func updateFooter() {
        footerTitle.attributedStringValue = selectedItem?.actions.first.map { Keycap.label($0.title, keys: "↵") } ?? NSAttributedString()
        footerActions.attributedStringValue = Keycap.label("Actions", keys: "⌘K")
        footerActions.isHidden = (selectedItem?.actions.count ?? 0) < 2
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        if !actionPanel.isHidden {
            if event.keyCode == 53 || KeyCombo.cmd("k").matches(event) { closeActionPanel(); return true }
            if actionPanel.handle(event) { return true }
        }
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        switch event.keyCode {
        case 125: move(1); return true // ↓
        case 126: move(-1); return true // ↑
        case 53 where mods == .command: // ⌘Esc: back to the root search
            popToRoot()
            return true
        case 53: // Esc
            if modes.count > 1 { pop() } else { hide() }
            return true
        case 48: // Tab
            if let item = selectedItem, let first = item.actions.first, item.pushesMode {
                perform(first, of: item, index: 0)
            }
            return true
        case 51 where query.isEmpty && modes.count > 1 && mods.isEmpty: // ⌫ on empty query
            pop()
            return true
        default: break
        }
        if KeyCombo.cmd("k").matches(event) { toggleActionPanel(); return true }

        if let item = selectedItem {
            for (i, action) in item.actions.enumerated() {
                let combo = i == 0 ? KeyCombo.ret() : action.shortcut
                if let combo, combo.matches(event) {
                    perform(action, of: item, index: i)
                    return true
                }
            }
        } else if event.keyCode == 36 || event.keyCode == 76, let result = current.submit(query) {
            handle(result)
            return true
        }

        // Standard editing shortcuts (an LSUIElement app has no Edit menu to route them).
        if mods == .command, let c = event.charactersIgnoringModifiers {
            let selector: Selector? = switch c {
            case "a": #selector(NSText.selectAll(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let selector { return NSApp.sendAction(selector, to: nil, from: self) }
        }
        return false
    }

    // MARK: - Actions

    private func perform(_ action: Action, of item: Item, index: Int) {
        closeActionPanel()
        if current === root { onItemPerformed?(item, index) }
        Task {
            let result = await action.perform()
            handle(result)
        }
    }

    private func handle(_ result: ActionResult) {
        switch result {
        case .dismiss: hide()
        case .dismissWithHUD(let t): hide(); HUD.shared.show(t)
        case .stay: break
        case .stayWithHUD(let t): HUD.shared.show(t)
        case .push(let m): push(m)
        case .pop: pop()
        case .reload: refresh(keepSelection: true)
        }
    }

    #if DEBUG
    func debugOpenActionPanel() { toggleActionPanel() }
    #endif

    private func toggleActionPanel() {
        if !actionPanel.isHidden { closeActionPanel(); return }
        guard let item = selectedItem, !item.actions.isEmpty else { return }
        actionPanel.show(item.actions)
        actionPanel.onPerform = { [weak self] action in
            guard let self, let i = item.actions.firstIndex(where: { $0.title == action.title }) else { return }
            self.perform(action, of: item, index: i)
        }
        actionPanelHeight.constant = actionPanel.preferredHeight
        actionPanel.isHidden = false
    }

    private func closeActionPanel() { actionPanel.isHidden = true }

    @objc private func tableClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case .item(let item) = rows[r] else { return }
        select(r)
        if let a = item.actions.first { perform(a, of: item, index: 0) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 30
        case .item(let item): return item.calculation == nil ? 40 : 116
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.tint = current.tint
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let v = tableView.makeView(withIdentifier: SectionHeaderView.identifier, owner: nil) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
            v.configure(title)
            return v
        case .item(let item) where item.calculation != nil:
            let v = tableView.makeView(withIdentifier: CalculationCellView.identifier, owner: nil) as? CalculationCellView
                ?? CalculationCellView(frame: .zero)
            let c = item.calculation!
            v.configure(c.expression, c.result, left: c.left, right: c.right)
            return v
        case .item(let item):
            let v = tableView.makeView(withIdentifier: ResultCellView.identifier, owner: nil) as? ResultCellView
                ?? ResultCellView(frame: .zero)
            v.configure(item)
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    // MARK: - Layout

    private func buildViews() {
        panel.appearance = Theme.darkAppearance
        let glass = NSGlassEffectView()
        glass.cornerRadius = panel.frameCornerRadius
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        let content = NSView()
        // DS surfaces are dark and quiet: a mostly opaque #0c0c09 over the glass.
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = panel.frameCornerRadius
        glass.contentView = content
        panel.contentView = glass

        for f in [searchField, secureField] {
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = Theme.search
            f.textColor = Theme.foreground
            f.delegate = self
            f.cell?.isScrollable = true
            f.cell?.wraps = false
        }
        secureField.isHidden = true

        modePill.font = Theme.sans(12, 500)
        modePill.wantsLayer = true
        modePill.layer?.cornerRadius = 6
        modePill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        modePill.isHidden = true
        modePill.setContentHuggingPriority(.required, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let fields = NSView()
        for f in [searchField, secureField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            fields.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
                f.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
                f.centerYAnchor.constraint(equalTo: fields.centerYAnchor),
            ])
        }
        let header = NSStackView(views: [modePill, fields, spinner, accessoryHolder])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 18)
        fields.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topDivider = NSBox()
        topDivider.boxType = .separator
        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        emptyLabel.textColor = Theme.mutedForeground
        emptyLabel.font = Theme.body
        emptyLabel.isHidden = true

        footerTitle.font = .systemFont(ofSize: 12, weight: .medium)
        footerTitle.textColor = .secondaryLabelColor
        footerActions.font = .systemFont(ofSize: 12, weight: .medium)
        footerActions.textColor = .secondaryLabelColor
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, footerTitle, footerActions])
        footer.spacing = 16
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        actionPanel.isHidden = true

        // The bunny as a faint watermark in the middle, behind everything.
        let watermark = WatermarkView(frame: NSRect(origin: .zero, size: LauncherPanel.size))
        watermark.autoresizingMask = [.width, .height]
        content.addSubview(watermark)

        for v in [header, topDivider, scroll, emptyLabel, bottomDivider, footer, actionPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        actionPanelHeight = actionPanel.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 62),
            fields.heightAnchor.constraint(equalToConstant: 30),
            topDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
            actionPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            actionPanel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            actionPanel.widthAnchor.constraint(equalToConstant: 320),
            actionPanelHeight,
        ])
    }
}

/// Draws the bunny logo centred and faint; outside Auto Layout so it can never size the window.
final class WatermarkView: NSView {
    private let image: NSImage? = Bundle.main.url(forResource: "bunny", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let s = superview { frame = s.bounds }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let b = superview?.bounds ?? bounds
        let side = b.height * 0.82
        let rect = NSRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.05)
    }
}
