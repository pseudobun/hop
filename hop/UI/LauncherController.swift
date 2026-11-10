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
    /// Seconds the root query survives the launcher being hidden; 0 = always start empty.
    var keepQueryFor: () -> Int = { 10 }
    /// Called at the start of every `show`, before the rows are built.
    var onWillShow: (() -> Void)?
    var onDidHide: (() -> Void)?
    /// ⌘, opens Settings, as in any Mac app.
    var onOpenSettings: (() -> Void)?

    private var rows: [Row] = []
    /// The mode `rows` were built for; a different mode gets a full reload (row tint, cell kinds).
    private var rowsMode: ObjectIdentifier?
    private var lastHidden = Date.distantPast
    private var loadingCount = 0
    private var autoHideSuppression = 0

    // Views
    private var searchField = NSTextField()
    private var secureField = NSSecureTextField()
    private var modePill = NSTextField(labelWithString: "")
    private var accessoryHolder = NSStackView()
    private var spinner = NSProgressIndicator()
    private var table = NSTableView()
    private var scroll = NSScrollView()
    /// Stands in for the table when the mode's layout is a grid (emoji).
    private var grid = GridResultsView()
    private var footerTitle = NSTextField(labelWithString: "")
    private var footerActions = NSTextField(labelWithString: "Actions  ⌘K")
    private var emptyLabel = NSTextField(labelWithString: "No results")
    private var actionPanel = ActionPanelView()
    private var actionPanelHeight: NSLayoutConstraint!
    /// Optional row under the search field, shown in the root search only (WireGuard tunnels).
    private var strip: LauncherStrip?
    private var stripHolder = NSView()
    private var stripHeight: NSLayoutConstraint!

    init(root: Mode) {
        self.root = root
        modes = [root]
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
    }

    func setStrip(_ view: LauncherStrip) {
        strip?.removeFromSuperview()
        strip = view
        view.translatesAutoresizingMaskIntoConstraints = false
        stripHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stripHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stripHolder.trailingAnchor),
            view.topAnchor.constraint(equalTo: stripHolder.topAnchor),
            view.heightAnchor.constraint(equalToConstant: Self.stripRowHeight),
        ])
        view.onContentChange = { [weak self] in self?.updateStrip() }
        updateStrip()
    }

    private static let stripRowHeight: CGFloat = 34

    /// Builds every view again with the current Theme, keeping the mode stack, the query
    /// and the selected row; the strip moves over as it is (it rethemes itself).
    func retheme() {
        let text = query
        let selectedID = selectedItem?.id
        let actionsOpen = !actionPanel.isHidden
        searchField = NSTextField()
        secureField = NSSecureTextField()
        modePill = NSTextField(labelWithString: "")
        accessoryHolder = NSStackView()
        spinner = NSProgressIndicator()
        table = NSTableView()
        scroll = NSScrollView()
        grid = GridResultsView()
        footerTitle = NSTextField(labelWithString: "")
        footerActions = NSTextField(labelWithString: "Actions  ⌘K")
        emptyLabel = NSTextField(labelWithString: "No results")
        actionPanel = ActionPanelView()
        stripHolder = NSView()
        buildViews()
        if let s = strip { strip = nil; setStrip(s) }
        rows = []
        rowsMode = nil
        enterCurrentMode(query: text)
        if loadingCount > 0 { spinner.startAnimation(nil) }
        refresh(selecting: selectedID)
        activeField.currentEditor()?.moveToEndOfDocument(nil)
        if actionsOpen { openActionPanel() }
    }

    private var stripShown: Bool { current === root && strip?.hasContent == true }

    private func updateStrip() {
        let shown = stripShown
        stripHolder.isHidden = !shown
        stripHeight.constant = shown ? Self.stripRowHeight : 0
        updateFooter()
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

    /// `mode` is the one in front.
    func isShowing(_ mode: Mode) -> Bool { current === mode }

    func show(query initial: String? = nil) {
        RunningApps.shared.refresh()
        onWillShow?()
        switch LauncherBehavior.reopen(elapsed: Date().timeIntervalSince(lastHidden), inSubMode: modes.count > 1,
                                       keepQueryFor: keepQueryFor(), popToRootSeconds: popToRootSeconds()) {
        case .restore: break
        case .clearQuery, .popToRoot:
            while modes.count > 1 { modes.removeLast().didExit() }
            enterCurrentMode(query: "")
            select(nil)
        }
        if let initial { activeField.stringValue = initial }
        // Reopening soon after comes back to the same query and row (selected below, so typing replaces it).
        refresh(keepSelection: initial == nil)
        panel.positionOnMouseScreen()
        panel.orderFrontRegardless()
        strip?.launcherDidShow()
        #if DEBUG
        // Offscreen renders must not take keystrokes from whatever the user is typing in.
        if UserDefaults.standard.bool(forKey: "DebugNoFocus") { return }
        #endif
        panel.makeKey()
        panel.makeFirstResponder(activeField)
        activeField.currentEditor()?.selectAll(nil)
    }

    /// Builds and lays out the current view while hidden, so the first show after launch
    /// (or after the app list changed) does not create cells while the user waits.
    func prepare() {
        guard !panel.isVisible else { return }
        refresh(keepSelection: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        guard !warmedUp else { return }
        // The first time a window is ordered in, the window server and the glass layers do
        // one-off setup; do it invisibly now rather than on the first ⌘Space.
        warmedUp = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private var warmedUp = false

    func hide() {
        guard panel.isVisible else { return }
        closeActionPanel()
        panel.orderOut(nil)
        strip?.launcherDidHide()
        lastHidden = Date()
        onDidHide?()
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
        updateStrip()
        accessoryHolder.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let accessory = current.accessoryView { accessoryHolder.addArrangedSubview(accessory) }
        panel.makeFirstResponder(activeField)
    }

    private var gridColumns: Int? {
        if case .grid(let columns) = current.layout { columns } else { nil }
    }

    private func refresh(keepSelection: Bool = false, selecting id: String? = nil) {
        let previousID = id ?? (keepSelection ? selectedItem?.id : nil)
        let sections = current.sections(for: query)
        scroll.isHidden = gridColumns != nil
        grid.isHidden = gridColumns == nil
        if let columns = gridColumns {
            if !rows.isEmpty { update(to: []) }
            grid.show(sections, columns: columns, tint: current.tint, keepingID: previousID)
            emptyLabel.isHidden = !grid.isEmpty || query.isEmpty
            updateFooter()
            return
        }
        if !grid.isEmpty { grid.show([], columns: 1, tint: nil, keepingID: nil) }
        var newRows: [Row] = []
        for s in sections where !s.items.isEmpty {
            if let t = s.title { newRows.append(.header(t)) }
            newRows.append(contentsOf: s.items.map(Row.item))
        }
        update(to: newRows)
        var target = firstItemRow(from: 0, step: 1)
        if let previousID, let i = rows.firstIndex(where: { if case .item(let it) = $0 { it.id == previousID } else { false } }) {
            target = i
        }
        select(target)
        emptyLabel.isHidden = !rows.isEmpty || query.isEmpty && current === root
    }

    /// Swaps in new rows. While the layout keeps its shape (same mode, same kind of row at
    /// each shared index) the cells on screen are reconfigured in place: `reloadData` tears
    /// down and rebuilds every visible row view, which was most of the cost of a keystroke.
    private func update(to newRows: [Row]) {
        let oldRows = rows
        rows = newRows
        let mode = ObjectIdentifier(current)
        // Within one mode rows are updated in place even when a header and an item swap
        // places (the fallback section moving as results change): those rows are reloaded
        // and their heights noted, the rest keep their views.
        let shared = min(oldRows.count, newRows.count)
        guard rowsMode == mode, !oldRows.isEmpty else {
            rowsMode = mode
            table.reloadData()
            return
        }
        // Results replace each other instantly: no row fades, no text cross-fades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if newRows.count < oldRows.count {
            table.removeRows(at: IndexSet(newRows.count..<oldRows.count), withAnimation: [])
        }
        // A header and an item that swapped places get fresh rows at their new height.
        let resized = IndexSet((0..<shared).filter { height(of: oldRows[$0]) != height(of: newRows[$0]) })
        if !resized.isEmpty {
            table.removeRows(at: resized, withAnimation: [])
            table.insertRows(at: resized, withAnimation: [])
        }
        var mismatched = IndexSet()
        table.enumerateAvailableRowViews { rowView, row in
            guard row < newRows.count, !configure(rowView.view(atColumn: 0) as? NSView, with: newRows[row]) else { return }
            mismatched.insert(row)
        }
        if !mismatched.isEmpty { table.reloadData(forRowIndexes: mismatched, columnIndexes: [0]) }
        if newRows.count > oldRows.count {
            table.insertRows(at: IndexSet(oldRows.count..<newRows.count), withAnimation: [])
        }
    }

    // MARK: - Selection

    private var selectedItem: Item? {
        if gridColumns != nil { return grid.selectedItem }
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
        current.selectionDidChange(selectedItem)
        if current === root, let strip, strip.isFocused {
            footerTitle.attributedStringValue = strip.focusedActionTitle.map { Keycap.label($0, keys: "↵") } ?? NSAttributedString()
            footerActions.attributedStringValue = Keycap.label("Back", keys: "esc")
            footerActions.isHidden = false
            return
        }
        footerTitle.attributedStringValue = selectedItem?.actions.first.map { Keycap.label($0.title, keys: "↵") } ?? NSAttributedString()
        footerActions.attributedStringValue = Keycap.label("Actions", keys: ["→", "⌘K"])
        footerActions.isHidden = (selectedItem?.actions.count ?? 0) < 2
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        if !actionPanel.isHidden {
            if event.keyCode == 53 || KeyCombo.cmd("k").matches(event) { closeActionPanel(); return true }
            // ← and Tab back out of the panel that → and Tab opened.
            let bare = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
            if bare && (event.keyCode == 123 || event.keyCode == 48) { closeActionPanel(); return true }
            if actionPanel.handle(event) { return true }
        }
        if current === root, let strip, strip.hasContent, strip.handle(event) { return true }
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        switch event.keyCode {
        case 125 where gridColumns != nil: grid.move(rows: 1); return true
        case 126 where gridColumns != nil: grid.move(rows: -1); return true
        case 123 where gridColumns != nil && mods.isEmpty: grid.move(columns: -1); return true // ←
        case 124 where gridColumns != nil && mods.isEmpty: grid.move(columns: 1); return true // →
        case 125: move(1); return true // ↓
        case 126: move(-1); return true // ↑
        case 53 where mods == .command: // ⌘Esc: back to the root search
            popToRoot()
            return true
        case 53: // Esc
            if modes.count > 1 { pop() } else { hide() }
            return true
        case 48: // Tab: complete a path, enter a sub-mode, or open the actions
            let item = selectedItem
            switch LauncherBehavior.tab(completion: current.complete(query), pushesMode: item?.pushesMode ?? false,
                                        actionCount: item?.actions.count ?? 0) {
            case .complete(let completed): setQuery(completed)
            case .enterMode: if let item, let first = item.actions.first { perform(first, of: item, index: 0) }
            case .openActions: openActionPanel()
            case .nothing: break
            }
            return true
        case 124 where mods.isEmpty && rightArrowOpensActions: // → at the end of the query
            openActionPanel()
            return true
        case 51 where query.isEmpty && modes.count > 1 && mods.isEmpty: // ⌫ on empty query
            pop()
            return true
        default: break
        }
        if KeyCombo.cmd("k").matches(event) { toggleActionPanel(); return true }
        if KeyCombo.cmd(",").matches(event), let onOpenSettings { onOpenSettings(); return true }

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
        case .failWithHUD(let t): HUD.shared.fail(t)
        case .warnWithHUD(let t): HUD.shared.warn(t)
        case .push(let m): push(m)
        case .pop: pop()
        case .reload: refresh(keepSelection: true)
        }
    }

    #if DEBUG
    func debugOpenActionPanel() { toggleActionPanel() }
    var debugActionPanelOpen: Bool { !actionPanel.isHidden }
    var debugSelectedID: String? { selectedItem?.id }
    #endif

    private var rightArrowOpensActions: Bool {
        let length = (query as NSString).length
        // Without an editor (the field is not focused) the caret counts as at the end.
        let selection = activeField.currentEditor()?.selectedRange ?? NSRange(location: length, length: 0)
        return LauncherBehavior.rightArrowOpensActions(selection: selection, textLength: length,
                                                       actionCount: selectedItem?.actions.count ?? 0)
    }

    private func toggleActionPanel() {
        if !actionPanel.isHidden { closeActionPanel(); return }
        openActionPanel()
    }

    private func openActionPanel() {
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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: rows[row]) }

    private func height(of row: Row) -> CGFloat {
        switch row {
        case .header: 30
        case .item(let item): item.calculation == nil ? 40 : 116
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = tableView.makeView(withIdentifier: ResultRowView.identifier, owner: nil) as? ResultRowView ?? {
            let v = ResultRowView()
            v.identifier = ResultRowView.identifier
            return v
        }()
        v.tint = current.tint
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v: NSView = switch rows[row] {
        case .header:
            tableView.makeView(withIdentifier: SectionHeaderView.identifier, owner: nil) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
        case .item(let item) where item.calculation != nil:
            tableView.makeView(withIdentifier: CalculationCellView.identifier, owner: nil) as? CalculationCellView
                ?? CalculationCellView(frame: .zero)
        case .item:
            tableView.makeView(withIdentifier: ResultCellView.identifier, owner: nil) as? ResultCellView
                ?? ResultCellView(frame: .zero)
        }
        configure(v, with: rows[row])
        return v
    }

    /// Fills `view` with `row`; false when the view is the wrong kind of cell for it.
    @discardableResult
    private func configure(_ view: NSView?, with row: Row) -> Bool {
        switch row {
        case .header(let title):
            guard let v = view as? SectionHeaderView else { return false }
            v.configure(title)
        case .item(let item):
            if let c = item.calculation {
                guard let v = view as? CalculationCellView else { return false }
                v.configure(c.expression, c.result, left: c.left, right: c.right, swatch: item.swatch)
            } else {
                guard let v = view as? ResultCellView else { return false }
                v.configure(item)
            }
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    // MARK: - Layout

    private func buildViews() {
        panel.appearance = Theme.appearance
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

        grid.isHidden = true
        grid.onSelectionChange = { [weak self] in self?.updateFooter() }
        grid.onActivate = { [weak self] item in
            if let a = item.actions.first { self?.perform(a, of: item, index: 0) }
        }
        stripHolder.isHidden = true
        for v in [header, stripHolder, topDivider, scroll, grid, emptyLabel, bottomDivider, footer, actionPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        actionPanelHeight = actionPanel.heightAnchor.constraint(equalToConstant: 100)
        stripHeight = stripHolder.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 62),
            fields.heightAnchor.constraint(equalToConstant: 30),
            stripHolder.topAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            stripHolder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stripHolder.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stripHeight,
            topDivider.topAnchor.constraint(equalTo: stripHolder.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            grid.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
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

/// The bunny logo centred and faint; outside Auto Layout so it can never size the window.
/// Rendered once into the layer's contents, so showing the panel never re-renders the SVG.
final class WatermarkView: NSView {
    private let image: NSImage? = Bundle.main.url(forResource: "bunny", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let s = superview { frame = s.bounds }
    }

    override func updateLayer() {
        guard let image, let layer, bounds.width > 0 else { return }
        let b = bounds
        let side = b.height * 0.82
        let rect = NSRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
        let rendered = NSImage(size: b.size, flipped: false) { _ in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.05)
            return true
        }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contents = rendered.layerContents(forContentsScale: scale)
    }
}
