import AppKit

/// The Settings window (⌘, in the launcher, "Settings" in root search): categories on the
/// left, grouped like the config; the selected one's values on the right. Every change is
/// written to `config.json5` at once (comments kept) and applies like a saved edit.
final class SettingsWindow: NSWindow {
    static let size = NSSize(width: 880, height: 620)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "hop Settings"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        standardWindowButton(.zoomButton)?.isEnabled = false
    }

    /// hop has no main menu, so the usual window and editing shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let c = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let selector: Selector? = switch (c, mods) {
        case ("w", .command), (",", .command): #selector(performClose(_:))
        case ("m", .command): #selector(performMiniaturize(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        case ("f", .command): #selector(SettingsController.focusSearch(_:))
        default: nil
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc closes, as in System Settings' sheets and hop's own panels.
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

final class SettingsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    private(set) var window = SettingsWindow()
    var onAction: ((SettingsAction) -> Void)?

    private let settings: AppSettings
    private var pageID = SettingsCatalog.general.id
    private var filter = ""
    private var previousApp: NSRunningApplication?

    private enum SidebarRow {
        case header(String)
        case page(SettingsPage)
    }

    private var sidebarRows: [SidebarRow] = []
    private let sidebar = NSTableView()
    private let search = NSSearchField()
    private let contentScroll = NSScrollView()
    private let contentStack = NSStackView()

    /// Controls on the current page, refreshed when the config changes.
    private var bindings: [(field: SettingsField, view: NSView, set: (Any?) -> Void)] = []
    private var gated: [NSView] = []
    private var fieldsByControl: [ObjectIdentifier: SettingsField] = [:]
    private var pluginsByControl: [ObjectIdentifier: PluginInfo] = [:]
    /// The line under a checked field that says what is wrong with its value.
    private var problemLabels: [String: NSTextField] = [:]

    private weak var plugins: PluginManager?

    init(settings: AppSettings, plugins: PluginManager? = nil) {
        self.settings = settings
        self.plugins = plugins
        super.init()
        build()
    }

    /// The running plugins' pages (installed ones included), or the built-in ones.
    private var groups: [SettingsGroup] {
        SettingsCatalog.groups(plugins: plugins?.pages ?? SettingsCatalog.builtinPluginPages)
    }

    private var pages: [SettingsPage] { groups.flatMap(\.pages) }

    var isVisible: Bool { window.isVisible }

    func show(page: String? = nil) {
        if let page, pages.contains(where: { $0.id == page }) {
            pageID = page
            // Search could hide the page asked for.
            if !filter.isEmpty {
                filter = ""
                search.stringValue = ""
            }
        }
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            window.center()
        }
        reloadSidebar()
        showPage()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if window.isVisible && window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    /// The config changed (here, in an editor, or a theme): show the new values.
    func configDidChange() {
        guard window.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if editingText { refreshValues() } else { showPage(keepScroll: true) }
        }
    }

    /// Builds the window again in the current theme, on the same page.
    func retheme() {
        let wasVisible = window.isVisible, frame = window.frame
        window.orderOut(nil)
        window.delegate = nil
        window = SettingsWindow()
        build()
        window.setFrame(frame, display: false)
        if wasVisible {
            reloadSidebar()
            showPage()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil) // commits a field being edited
        if let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }

    // MARK: - Layout

    private static let sidebarWidth: CGFloat = 224
    private static let contentWidth: CGFloat = SettingsWindow.size.width - sidebarWidth
    private static let pad: CGFloat = 32
    /// Width of a row's text column next to its control.
    private static let textWidth: CGFloat = 260

    private func build() {
        window.delegate = self
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.background

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor
        window.contentView = root

        // Sidebar
        let side = NSView()
        side.wantsLayer = true
        side.layer?.backgroundColor = Theme.card.cgColor
        side.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        search.placeholderString = "Search settings"
        search.font = Theme.sans(13)
        search.focusRingType = .none
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(search)

        let column = NSTableColumn(identifier: .init("page"))
        sidebar.tableColumns.forEach { sidebar.removeTableColumn($0) }
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.backgroundColor = .clear
        sidebar.selectionHighlightStyle = .none
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.focusRingType = .none
        sidebar.style = .plain
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.scrollerStyle = .overlay
        sideScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(sideScroll)

        // Content
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 46, left: Self.pad, bottom: Self.pad, right: Self.pad)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setHuggingPriority(.required, for: .vertical)
        doc.addSubview(contentStack)
        contentScroll.documentView = doc
        contentScroll.drawsBackground = false
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.scrollerStyle = .overlay
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            search.topAnchor.constraint(equalTo: side.topAnchor, constant: 44),
            search.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -12),
            sideScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            sideScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 8),
            sideScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -8),
            sideScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),

            contentScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: root.topAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: doc.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: - Sidebar

    @objc func focusSearch(_ sender: Any?) { window.makeFirstResponder(search) }

    @objc private func searchChanged() {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        reloadSidebar()
        // Follow the filter to the first match when the open page dropped out.
        if !visiblePages.contains(where: { $0.id == pageID }), let first = visiblePages.first {
            pageID = first.id
            showPage()
        }
        selectCurrentRow()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            window.makeFirstResponder(sidebar)
            return true
        case #selector(NSResponder.cancelOperation(_:)) where !search.stringValue.isEmpty:
            search.stringValue = ""
            searchChanged()
            return true
        default:
            return false
        }
    }

    private var visiblePages: [SettingsPage] {
        sidebarRows.compactMap { if case .page(let p) = $0 { p } else { nil } }
    }

    private func reloadSidebar() {
        let words = filter.split(separator: " ")
        sidebarRows = []
        for group in groups {
            let pages = group.pages.filter { page in words.allSatisfy { page.haystack.contains($0) } }
            guard !pages.isEmpty else { continue }
            sidebarRows.append(.header(group.title))
            sidebarRows += pages.map { .page($0) }
        }
        sidebar.reloadData()
        selectCurrentRow()
    }

    private func selectCurrentRow() {
        guard let row = sidebarRows.firstIndex(where: { if case .page(let p) = $0 { p.id == pageID } else { false } }) else {
            sidebar.deselectAll(nil)
            return
        }
        sidebar.selectRowIndexes([row], byExtendingSelection: false)
        sidebar.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = sidebarRows[row] { return row == 0 ? 22 : 34 }
        return 30
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sidebarRows[row] {
        case .header(let title):
            let cell = NSView()
            let label = NSTextField(labelWithAttributedString: Theme.labelString(title))
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .page(let page):
            let cell = NSView()
            let icon = NSImageView(image: IconCache.shared.image(for: .tile(page.symbol, page.color), size: 20) ?? NSImage())
            let label = NSTextField(labelWithString: page.title)
            label.font = Theme.sans(13.5, page.id == pageID ? 500 : 400)
            label.textColor = Theme.foreground
            label.lineBreakMode = .byTruncatingTail
            for v in [icon, label] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < sidebarRows.count, case .page(let page) = sidebarRows[row], page.id != pageID else { return }
        window.makeFirstResponder(sidebar) // commits a field being edited on the old page
        pageID = page.id
        sidebar.reloadData(forRowIndexes: IndexSet(integersIn: 0..<sidebarRows.count), columnIndexes: [0])
        showPage()
    }

    // MARK: - Page

    private var page: SettingsPage {
        pages.first { $0.id == pageID } ?? SettingsCatalog.general
    }

    private var editingText: Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.isDescendant(of: contentStack)
            || (editor.delegate as? NSView)?.isDescendant(of: contentStack) == true
    }

    private func showPage(keepScroll: Bool = false) {
        let scroll = contentScroll.contentView.bounds.origin
        bindings = []
        gated = []
        fieldsByControl = [:]
        pluginsByControl = [:]
        problemLabels = [:]
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let page = page
        let config = settings.data

        contentStack.addArrangedSubview(header(page))
        contentStack.setCustomSpacing(22, after: contentStack.arrangedSubviews.last!)
        if let error = settings.error {
            let banner = errorBanner(error)
            contentStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -2 * Self.pad).isActive = true
            contentStack.setCustomSpacing(22, after: banner)
        }
        for section in page.sections {
            if section.footer {
                contentStack.addArrangedSubview(AuthorFooter.make(
                    width: Self.contentWidth - 2 * Self.pad,
                    style: .init(foreground: Theme.foreground, muted: Theme.mutedForeground, line: Theme.border,
                                 font: { Theme.sans($0, $1) })))
                continue
            }
            if let title = section.title {
                let label = NSTextField(labelWithAttributedString: Theme.labelString(title))
                contentStack.addArrangedSubview(label)
                contentStack.setCustomSpacing(8, after: label)
            }
            let card = Card()
            var views: [NSView] = []
            for row in section.rows {
                switch row {
                case .field(let field) where field.hidden: continue
                case .field(let field): views.append(fieldRow(field, page: page, config: config))
                case .info(let info): views.append(infoRow(info, config: config))
                case .plugins: views += pluginRows(config: config)
                case .installPlugin: views.append(installRow())
                case .pluginEnabled:
                    if let plugin = page.plugin { views.append(pluginSwitchRow(plugin, config: config)) }
                }
            }
            guard !views.isEmpty else {
                if section.title != nil, let label = contentStack.arrangedSubviews.last { label.removeFromSuperview() }
                continue
            }
            for (i, view) in views.enumerated() {
                if i > 0 { card.stack.addArrangedSubview(Hairline()) }
                card.stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
            }
            contentStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -2 * Self.pad).isActive = true
            contentStack.setCustomSpacing(24, after: card)
        }
        addHiddenFields(page)
        refreshGate()
        contentStack.layoutSubtreeIfNeeded()
        contentScroll.contentView.scroll(to: keepScroll ? scroll : .zero)
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
    }

    private func header(_ page: SettingsPage) -> NSView {
        let icon = NSImageView(image: IconCache.shared.image(for: .tile(page.symbol, page.color), size: 36) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = NSTextField(labelWithString: page.title)
        title.font = Theme.heading(22, Theme.spec(Theme.variant).titleWeight)
        title.textColor = Theme.foreground
        let subtitle = NSTextField(labelWithString: page.subtitle)
        subtitle.font = Theme.meta
        subtitle.textColor = Theme.mutedForeground
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text])
        row.spacing = 14
        row.alignment = .centerY
        return row
    }

    private func errorBanner(_ error: ConfigIssue) -> NSView {
        let card = Card(tint: Theme.destructive)
        let text = label("The config can't be read: \(error.message) hop keeps using the last config that read; fix the file to change settings again.",
                         help: true, width: Self.contentWidth - 2 * Self.pad - 220)
        text.textColor = Theme.foreground
        let button = self.button("Open Config") { [weak self] in self?.onAction?(.openConfig) }
        let row = rowStack([text, button])
        card.stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        return card
    }

    // MARK: Plugin rows

    /// Keys a page keeps out of sight, listed with a way to the config.
    private func addHiddenFields(_ page: SettingsPage) {
        let hidden = page.fields.filter(\.hidden)
        guard !hidden.isEmpty else { return }
        let label = NSTextField(labelWithAttributedString: Theme.labelString("More in the config"))
        contentStack.addArrangedSubview(label)
        contentStack.setCustomSpacing(8, after: label)
        let card = Card()
        let info = SettingsInfo(label: hidden.count == 1 ? "1 more setting" : "\(hidden.count) more settings",
                                help: "Rarely changed; set them in config.json5.",
                                lines: { _ in hidden.map { "\($0.key)  ·  \($0.label)" } },
                                button: "Edit in Config", action: .openConfig)
        let row = infoRow(info, config: settings.data)
        card.stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -2 * Self.pad).isActive = true
        contentStack.setCustomSpacing(24, after: card)
    }

    /// One row per plugin: icon, name, what it does and who made it, its page, its switch.
    private func pluginRows(config: HopConfig) -> [NSView] {
        let all = plugins?.plugins.map(\.info) ?? BuiltinPlugins.types.map { $0.info }
        guard !all.isEmpty else { return [] }
        return all.map { info in
            let icon = NSImageView(image: IconCache.shared.image(for: .tile(info.symbol, info.color), size: 28) ?? NSImage())
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            var meta = [info.tier.label]
            if let version = info.version { meta.append(version) }
            if let author = info.author { meta.append(author) }
            let text = textColumn(info.name, "\(info.summary)\n\(meta.joined(separator: " · "))", width: Self.textWidth + 40)
            let left = NSStackView(views: [icon, text])
            left.spacing = 12
            left.alignment = .centerY

            var controls: [NSView] = []
            if info.tier != .builtin {
                let id = info.id
                controls.append(button("Remove") { [weak self] in self?.onAction?(.removePlugin(id)) })
            }
            let id = info.id
            controls.append(button("Settings") { [weak self] in self?.onAction?(.showPage(id)) })
            controls.append(pluginSwitch(info, config: config))
            let right = NSStackView(views: controls)
            right.spacing = 10
            right.alignment = .centerY
            return rowStack([left, right])
        }
    }

    private func pluginSwitchRow(_ info: PluginInfo, config: HopConfig) -> NSView {
        rowStack([textColumn(info.name, "Turns the plugin's commands, hotkeys and background work on or off."),
                  pluginSwitch(info, config: config)])
    }

    private func pluginSwitch(_ info: PluginInfo, config: HopConfig) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = info.isEnabled(in: config) ? .on : .off
        toggle.target = self
        toggle.action = #selector(pluginToggled(_:))
        pluginsByControl[ObjectIdentifier(toggle)] = info
        return toggle
    }

    @objc private func pluginToggled(_ sender: NSSwitch) {
        guard let info = pluginsByControl[ObjectIdentifier(sender)] else { return }
        if !info.setEnabled(sender.state == .on, in: settings) {
            HUD.shared.fail("Could not save \(info.name) to the config")
        }
    }

    private func installRow() -> NSView {
        let field = NSTextField()
        field.placeholderString = "github.com/owner/repo"
        field.font = Theme.mono(12.5)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let install = button("Install") { [weak self, weak field] in
            guard let link = field?.stringValue.trimmingCharacters(in: .whitespaces), !link.isEmpty else { return }
            self?.onAction?(.installPlugin(link))
        }
        let controls = NSStackView(views: [field, install])
        controls.spacing = 8
        let text = textColumn("GitHub link",
                              "A repository with a hop plugin release. Plugins from GitHub run as their own program with your permissions: install only code you trust.")
        return rowStack([text, controls])
    }

    // MARK: Rows

    private func label(_ text: String, help: Bool = false, width: CGFloat = textWidth) -> NSTextField {
        let l = help ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        l.font = help ? Theme.sans(12) : Theme.sans(13.5, 500)
        l.textColor = help ? Theme.mutedForeground : Theme.foreground
        l.isSelectable = false
        if help {
            // Measured and drawn at the same width, so a wrapped help text gets its full height.
            l.preferredMaxLayoutWidth = width
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return l
    }

    private func textColumn(_ title: String, _ help: String?, width: CGFloat = textWidth, lines: [String] = []) -> NSStackView {
        var views: [NSView] = [label(title)]
        if let help, !help.isEmpty { views.append(label(help, help: true, width: width)) }
        for line in lines {
            let l = NSTextField(labelWithString: line)
            l.font = Theme.mono(12)
            l.textColor = Theme.foreground
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(l)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        if !lines.isEmpty { stack.setCustomSpacing(8, after: views[views.count - lines.count - 1]) }
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// Text on the left, pinned to the row's padding so it sets the height; the control
    /// on the right, centred.
    private func rowStack(_ views: [NSView]) -> NSView {
        let row = NSView()
        let text = views[0], control = views[1]
        for v in [text, control] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        text.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 16),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
        ])
        return row
    }

    private func infoRow(_ info: SettingsInfo, config: HopConfig) -> NSView {
        let lines = info.lines(config)
        let text = textColumn(info.label, info.help, width: Self.textWidth + 100,
                              lines: lines.isEmpty && info.action == .openConfig ? ["None yet"] : lines)
        let action = info.action
        return rowStack([text, button(info.button) { [weak self] in self?.onAction?(action) }])
    }

    private func fieldRow(_ field: SettingsField, page: SettingsPage, config: HopConfig) -> NSView {
        let value = SettingsValue.read(field.path, in: config) ?? field.fallback
        let isGate = field.path == page.gate
        let row: NSView
        switch field.kind {
        case .toggle:
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = (value as? Bool) == true ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            fieldsByControl[ObjectIdentifier(toggle)] = field
            bindings.append((field, toggle, { toggle.state = ($0 as? Bool) == true ? .on : .off }))
            row = rowStack([textColumn(field.label, field.help), toggle])
        case .text(let placeholder):
            let text = textField(field, value: value as? String ?? "", placeholder: placeholder, width: 240)
            row = rowStack([checkedColumn(field, value: value as? String ?? ""), text])
        case .list(let placeholder):
            let joined = (value as? [String] ?? []).joined(separator: ", ")
            let text = textField(field, value: joined, placeholder: placeholder, width: 240)
            bindings.removeLast()
            bindings.append((field, text, { text.stringValue = ($0 as? [String] ?? []).joined(separator: ", ") }))
            row = rowStack([checkedColumn(field, value: value as? [String] ?? []), text])
        case .number(let min, let max, let unit):
            let number = value as? Int ?? 0
            let text = textField(field, value: String(number), placeholder: "", width: 72)
            text.alignment = .right
            let stepper = NSStepper()
            stepper.minValue = Double(min)
            stepper.maxValue = Double(max)
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.integerValue = number
            stepper.controlSize = .small
            stepper.target = self
            stepper.action = #selector(stepped(_:))
            fieldsByControl[ObjectIdentifier(stepper)] = field
            bindings.removeLast()
            bindings.append((field, text, {
                text.stringValue = String($0 as? Int ?? 0)
                stepper.integerValue = $0 as? Int ?? 0
            }))
            var controls: [NSView] = [text, stepper]
            if !unit.isEmpty {
                let u = NSTextField(labelWithString: unit)
                u.font = Theme.meta
                u.textColor = Theme.mutedForeground
                controls.append(u)
            }
            let group = NSStackView(views: controls)
            group.spacing = 6
            row = rowStack([textColumn(field.label, field.help), group])
        case .choice(let options):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .regular
            popup.font = Theme.sans(13)
            for option in options {
                popup.addItem(withTitle: option.label)
                popup.lastItem?.representedObject = option.value
            }
            let select = { (value: Any?) in
                let raw = value as? String ?? ""
                if let i = options.firstIndex(where: { $0.value == raw }) { popup.selectItem(at: i) }
            }
            select(value)
            popup.target = self
            popup.action = #selector(chose(_:))
            fieldsByControl[ObjectIdentifier(popup)] = field
            bindings.append((field, popup, select))
            row = rowStack([textColumn(field.label, field.help), popup])
        case .hotkey(let optional):
            let recorder = HotkeyRecorder(optional: optional)
            recorder.value = value as? String ?? ""
            recorder.onChange = { [weak self] spec in self?.write(field, ConfigEdit.literal(spec)) }
            bindings.append((field, recorder, { recorder.value = $0 as? String ?? "" }))
            row = rowStack([textColumn(field.label, field.help), recorder])
        case .secret(let service, let account):
            let secure = NSSecureTextField()
            let saved = Keychain.read(service: service, account: account) != nil
            secure.placeholderString = saved ? "Saved in the Keychain · type to replace" : "Not set"
            secure.font = Theme.sans(13)
            secure.delegate = self
            secure.widthAnchor.constraint(equalToConstant: 240).isActive = true
            fieldsByControl[ObjectIdentifier(secure)] = field
            var controls: [NSView] = [secure]
            if saved {
                controls.append(button("Remove") { [weak self] in
                    Keychain.delete(service: service, account: account)
                    self?.showPage(keepScroll: true)
                })
            }
            let group = NSStackView(views: controls)
            group.spacing = 8
            row = rowStack([textColumn(field.label, field.help), group])
        case .multiline:
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.string = value as? String ?? ""
            tv.font = Theme.mono(12.5)
            tv.textColor = Theme.foreground
            tv.backgroundColor = Theme.wash(0.04)
            tv.insertionPointColor = Theme.foreground
            tv.isRichText = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.allowsUndo = true
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.delegate = self
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = Theme.border.cgColor
            scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
            fieldsByControl[ObjectIdentifier(tv)] = field
            bindings.append((field, tv, { tv.string = $0 as? String ?? "" }))
            let column = NSStackView(views: [textColumn(field.label, field.help, width: 520), scroll])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 10
            column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true
            row = column
        }
        if page.gate != nil && !isGate { gated.append(row) }
        return row
    }

    private func textField(_ field: SettingsField, value: String, placeholder: String, width: CGFloat) -> NSTextField {
        let text = NSTextField(string: value)
        text.placeholderString = placeholder
        text.font = Theme.mono(12.5)
        text.textColor = Theme.foreground
        text.isBordered = true
        text.isBezeled = true
        text.bezelStyle = .roundedBezel
        text.focusRingType = .default
        text.lineBreakMode = .byTruncatingTail
        text.usesSingleLineMode = true
        text.cell?.isScrollable = true
        text.delegate = self
        text.widthAnchor.constraint(equalToConstant: width).isActive = true
        fieldsByControl[ObjectIdentifier(text)] = field
        bindings.append((field, text, { text.stringValue = $0 as? String ?? "" }))
        return text
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .push
        b.controlSize = .regular
        b.font = Theme.sans(13)
        return b
    }

    private func refreshValues() {
        let config = settings.data
        let editor = window.firstResponder as? NSTextView
        for binding in bindings {
            // Leave the field being typed in alone.
            if let editor, editor === binding.view || editor.delegate === binding.view as AnyObject { continue }
            let value = SettingsValue.read(binding.field.path, in: config) ?? binding.field.fallback
            binding.set(value)
            if let check = binding.field.check, let value { showProblem(check(value), for: binding.field) }
        }
        refreshGate()
    }

    private func refreshGate() {
        guard let gate = page.gate else { return }
        let on = SettingsValue.read(gate, in: settings.data) as? Bool ?? true
        for view in gated {
            view.alphaValue = on ? 1 : 0.45
            Self.setEnabled(on, in: view)
        }
    }

    private static func setEnabled(_ on: Bool, in view: NSView) {
        if let control = view as? NSControl { control.isEnabled = on }
        if let tv = view as? NSTextView { tv.isEditable = on; tv.isSelectable = on }
        for sub in view.subviews { setEnabled(on, in: sub) }
    }

    // MARK: - Writing

    private func write(_ field: SettingsField, _ literal: String) {
        if !settings.update(field.path, to: literal) {
            HUD.shared.fail("Could not save \(field.key) to the config")
        }
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let field = fieldsByControl[ObjectIdentifier(sender)] else { return }
        write(field, ConfigEdit.literal(sender.state == .on))
        refreshGate()
    }

    @objc private func chose(_ sender: NSPopUpButton) {
        guard let field = fieldsByControl[ObjectIdentifier(sender)],
              let value = sender.selectedItem?.representedObject as? String else { return }
        if (SettingsValue.read(field.path, in: settings.data) ?? field.fallback) as? String == value { return }
        write(field, ConfigEdit.literal(value))
    }

    @objc private func stepped(_ sender: NSStepper) {
        guard let field = fieldsByControl[ObjectIdentifier(sender)] else { return }
        write(field, ConfigEdit.literal(sender.integerValue))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let text = obj.object as? NSTextField, text !== search,
              let field = fieldsByControl[ObjectIdentifier(text)] else { return }
        commit(field, text.stringValue, revert: { text.stringValue = $0 })
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, let field = fieldsByControl[ObjectIdentifier(tv)] else { return }
        commit(field, tv.string, revert: { tv.string = $0 })
    }

    // MARK: Checks

    /// The field's text column, with a line for what is wrong with `value` when it has a check.
    private func checkedColumn(_ field: SettingsField, value: Any) -> NSStackView {
        let column = textColumn(field.label, field.help)
        guard field.check != nil else { return column }
        let line = NSTextField(wrappingLabelWithString: "")
        line.font = Theme.sans(12, 500)
        line.preferredMaxLayoutWidth = Self.textWidth
        line.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        column.addArrangedSubview(line)
        problemLabels[field.key] = line
        showProblem(field.check?(value), for: field)
        return column
    }

    private func showProblem(_ problem: SettingsProblem?, for field: SettingsField) {
        guard let line = problemLabels[field.key] else { return }
        line.isHidden = problem == nil
        line.stringValue = problem.map { ($0.level == .error ? "✕ " : "⚠︎ ") + $0.message } ?? ""
        line.textColor = problem?.level == .error ? Theme.destructive : Theme.warn
    }

    /// What a text control's input means for its field.
    private static func parsed(_ field: SettingsField, _ input: String) -> Any {
        switch field.kind {
        case .list: input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .number: Int(input.trimmingCharacters(in: .whitespaces)) ?? 0
        default: input.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Checks as you type.
    func controlTextDidChange(_ obj: Notification) {
        guard let text = obj.object as? NSTextField, text !== search,
              let field = fieldsByControl[ObjectIdentifier(text)], let check = field.check else { return }
        showProblem(check(Self.parsed(field, text.stringValue)), for: field)
    }

    private func commit(_ field: SettingsField, _ input: String, revert: (String) -> Void) {
        let current = SettingsValue.read(field.path, in: settings.data) ?? field.fallback
        if let check = field.check {
            let problem = check(Self.parsed(field, input))
            showProblem(problem, for: field)
            // An error stays in the field, unsaved, until it is fixed or the page is left.
            if problem?.level == .error {
                NSSound.beep()
                return
            }
        }
        switch field.kind {
        case .secret(let service, let account):
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if Keychain.write(value, service: service, account: account, label: "hop: \(field.label)") {
                HUD.shared.show("Saved to the Keychain")
                revert("")
                DispatchQueue.main.async { [weak self] in self?.showPage(keepScroll: true) }
            } else {
                HUD.shared.fail("Could not save \(field.label) to the Keychain")
            }
        case .text, .multiline:
            let value = field.kind.isMultiline ? input : input.trimmingCharacters(in: .whitespaces)
            if value != current as? String { write(field, ConfigEdit.literal(value)) }
        case .list:
            let values = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if values != current as? [String] { write(field, ConfigEdit.literal(values)) }
        case .number(let min, let max, _):
            guard let n = Int(input.trimmingCharacters(in: .whitespaces)), (min...max).contains(n) else {
                NSSound.beep()
                revert(String(current as? Int ?? 0))
                return
            }
            if n != current as? Int { write(field, ConfigEdit.literal(n)) }
        case .toggle, .choice, .hotkey:
            break
        }
    }
}

private extension SettingsField.Kind {
    var isMultiline: Bool { if case .multiline = self { true } else { false } }
}

// MARK: - Small views

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded card holding rows separated by hairlines.
private final class Card: NSView {
    let stack = NSStackView()

    init(tint: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (tint?.withAlphaComponent(0.10) ?? Theme.card).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (tint?.withAlphaComponent(0.35) ?? Theme.border).cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class Hairline: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.border.cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.wash(Theme.isLight ? 0.07 : 0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override var isSelected: Bool { didSet { needsDisplay = true } }
}

private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}

/// Click, then press the keys: writes hotkey syntax ("shift+alt+c"). Esc cancels;
/// ⌫ clears an optional one.
final class HotkeyRecorder: NSView {
    var value = "" { didSet { update() } }
    var onChange: ((String) -> Void)?

    private let optional: Bool
    private let button = NSButton()
    private let clear = NSButton()
    private var monitor: Any?
    private var recording = false { didSet { update() } }

    init(optional: Bool) {
        self.optional = optional
        super.init(frame: .zero)
        button.bezelStyle = .push
        button.font = Theme.mono(12.5, 500)
        button.target = self
        button.action = #selector(toggleRecording)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clear.contentTintColor = Theme.mutedForeground
        clear.target = self
        clear.action = #selector(clearValue)
        clear.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clear)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 196),
            heightAnchor.constraint(equalTo: button.heightAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -4),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor),
            clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 16),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        if recording {
            button.title = "Press keys…"
        } else if value.isEmpty {
            button.title = optional ? "Record Hotkey" : "None"
        } else {
            button.title = HotkeySpec.parse(value) == nil ? "\(value) (invalid)" : HotkeySpec.display(value)
        }
        clear.isHidden = !optional || value.isEmpty || recording
    }

    @objc private func toggleRecording() {
        recording ? stop() : start()
    }

    @objc private func clearValue() {
        value = ""
        onChange?("")
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                // A click anywhere else ends recording without a change.
                if event.window !== window || !button.frame.contains(convert(event.locationInWindow, from: nil)) { stop() }
                return event
            }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && mods.isEmpty { stop(); return nil }
            if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty && optional {
                stop()
                clearValue()
                return nil
            }
            guard let spec = Self.spec(keyCode: event.keyCode, modifiers: mods) else {
                NSSound.beep()
                return nil
            }
            stop()
            if spec != value {
                value = spec
                onChange?(spec)
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    private static let names: [Int: String] = {
        var names: [Int: String] = [:]
        for (name, code) in HotkeySpec.keyCodes where names[code] == nil || name == "return" { names[code] = name }
        return names
    }()

    /// Hotkey syntax for a key press: modifiers as ctrl, alt, shift, cmd (all four: hyper).
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = names[Int(keyCode)] else { return nil }
        var parts: [String] = []
        if modifiers.isSuperset(of: [.command, .control, .option, .shift]) {
            parts = ["hyper"]
        } else {
            if modifiers.contains(.control) { parts.append("ctrl") }
            if modifiers.contains(.option) { parts.append("alt") }
            if modifiers.contains(.shift) { parts.append("shift") }
            if modifiers.contains(.command) { parts.append("cmd") }
        }
        let spec = (parts + [key]).joined(separator: "+")
        return HotkeySpec.parse(spec) == nil ? nil : spec
    }
}
