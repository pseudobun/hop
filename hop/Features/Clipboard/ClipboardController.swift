import AppKit
import ImageIO

/// The clipboard history window (⇧⌥C). Non-activating like the launcher, so the app
/// you were in stays frontmost and ↵ can paste straight into it.
final class ClipboardPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
                   styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = NSSize(width: 640, height: 380)
        appearance = Theme.darkAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

nonisolated enum ClipboardFilter: String, CaseIterable, Sendable {
    case all = "All Types", pinned = "Pinned", text = "Text", image = "Images", link = "Links", color = "Colors", file = "Files"

    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .pinned: item.pinned
        case .text: item.kind == .text
        case .image: item.kind == .image
        case .link: item.kind == .link
        case .color: item.kind == .color
        case .file: item.kind == .file
        }
    }
}

/// Lists the history on the left and previews the selected entry on the right.
final class ClipboardController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let panel = ClipboardPanel()
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let settings: AppSettings
    private var config: HopConfig.Clipboard { settings.data.clipboard }

    private enum Row {
        case header(String)
        case item(ClipboardItem)
    }

    private var rows: [Row] = []
    private var shownCount = 0
    private var filter: ClipboardFilter = .all
    private var deleteAllArmedUntil: Date?
    /// 48 px row thumbnails (~9 KB each), made only for rows that are drawn.
    private let thumbnails: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    /// Adds text to the snippets file; false when it could not.
    var saveSnippet: ((String) -> Bool)?
    private static let frameName = "hop.clipboard"

    // Views
    private let searchField = NSTextField()
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let previewBox = NSView()
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let colorView = ClipColorView()
    private let infoStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing copied yet")
    private let countLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let actionPanel = ActionPanelView()
    private var actionPanelHeight: NSLayoutConstraint!

    init(store: ClipboardStore, monitor: ClipboardMonitor, settings: AppSettings) {
        self.store = store
        self.monitor = monitor
        self.settings = settings
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        panel.setFrameAutosaveName(Self.frameName)
        store.onChange = { [weak self] in
            guard let self, panel.isVisible else { return }
            reload(keepSelection: true)
        }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        // A copy made in the last poll period shows up at the top right away.
        monitor.check()
        store.prune(keepDays: config.keepDays, maxItems: config.maxItems)
        searchField.stringValue = ""
        filter = .all
        filterPopup.selectItem(withTitle: filter.rawValue)
        deleteAllArmedUntil = nil
        closeActionPanel()
        reload(keepSelection: false)
        // Centred like the launcher every time; only the size you leave it at is remembered.
        panel.positionOnMouseScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        guard panel.isVisible else { return }
        closeActionPanel()
        panel.orderOut(nil)
        // The preview holds a full-size decoded image (or a long text); don't keep it while hidden.
        imageView.image = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    func windowDidResize(_ notification: Notification) { updateFooter() }

    // MARK: - Rows

    private var query: String { searchField.stringValue }

    private func reload(keepSelection: Bool) {
        let previous = keepSelection ? selectedItem?.id : nil
        let visible = store.items.filter { filter.includes($0) && $0.matches(query) }
        shownCount = visible.count
        rows = []
        let pinned = filter == .pinned ? [] : visible.filter(\.pinned)
        if !pinned.isEmpty {
            rows.append(.header("Pinned"))
            rows += pinned.map(Row.item)
        }
        var lastGroup: String?
        let now = Date()
        for item in visible where filter == .pinned || !item.pinned {
            let group = ClipboardGroups.title(for: item.lastCopied, now: now)
            if group != lastGroup {
                rows.append(.header(group))
                lastGroup = group
            }
            rows.append(.item(item))
        }
        table.reloadData()
        var target = rows.firstIndex { if case .item = $0 { true } else { false } }
        if let previous, let i = rows.firstIndex(where: { if case .item(let it) = $0 { it.id == previous } else { false } }) { target = i }
        select(target)
        emptyLabel.isHidden = shownCount > 0
        emptyLabel.stringValue = store.items.isEmpty ? "Nothing copied yet" : "No matches"
        let total = store.items.count
        countLabel.attributedStringValue = Theme.labelString(shownCount == total ? "\(total) items" : "\(shownCount) of \(total)")
    }

    private var selectedItem: ClipboardItem? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .item(let item) = rows[r] else { return nil }
        return item
    }

    private func select(_ row: Int?) {
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row == firstItemRow(from: 0, step: 1) ? 0 : row)
        } else {
            table.deselectAll(nil)
        }
        updatePreview()
        updateFooter()
    }

    private func firstItemRow(from start: Int, step: Int) -> Int? {
        var i = start
        while i >= 0 && i < rows.count {
            if case .item = rows[i] { return i }
            i += step
        }
        return nil
    }

    private func move(_ step: Int) {
        let start = table.selectedRow < 0 ? (step > 0 ? 0 : rows.count - 1) : table.selectedRow + step
        if let next = firstItemRow(from: start, step: step) { select(next) }
    }

    // MARK: - Actions

    private var targetName: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "App" }

    private func actions(for item: ClipboardItem) -> [Action] {
        let paste = Action(title: "Paste to \(targetName)", symbol: "doc.on.clipboard") { [weak self] in
            self?.paste(item)
            return .stay
        }
        let copy = Action(title: "Copy to Clipboard", symbol: "doc.on.doc") { [weak self] in
            self?.copy(item)
            return .stay
        }
        var list: [Action] = config.pasteOnReturn
            ? [paste, Action(title: copy.title, symbol: "doc.on.doc", shortcut: .ret(.command), perform: copy.perform)]
            : [copy, Action(title: paste.title, symbol: "doc.on.clipboard", shortcut: .ret(.command), perform: paste.perform)]
        if item.kind == .text && item.rtfFile != nil {
            list.append(Action(title: "Paste as Plain Text", symbol: "textformat", shortcut: .ret(.shift)) { [weak self] in
                self?.paste(item, plain: true)
                return .stay
            })
        }
        switch item.kind {
        case .link:
            list.append(Action(title: "Open Link", symbol: "safari", shortcut: .cmd("o")) { [weak self] in
                if let url = URL(string: item.text) { NSWorkspace.shared.open(url) }
                self?.hide()
                return .stay
            })
        case .file:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) }
            list.append(Action(title: "Open", symbol: "arrow.up.forward.app", shortcut: .cmd("o")) { [weak self] in
                urls.forEach { NSWorkspace.shared.open($0) }
                self?.hide()
                return .stay
            })
            list.append(Action(title: "Show in Finder", symbol: "folder", shortcut: .cmd("f", .shift)) { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                self?.hide()
                return .stay
            })
        case .image:
            list.append(Action(title: "Open in Preview", symbol: "photo", shortcut: .cmd("o")) { [weak self] in
                if let url = self?.store.imageURL(item) { NSWorkspace.shared.open(url) }
                self?.hide()
                return .stay
            })
        case .color:
            if let c = ClipColor.parse(item.text) {
                for (format, value) in [("HEX", c.hex), ("RGB", c.rgb), ("HSL", c.hsl)] where value != item.text {
                    list.append(Action(title: "Copy as \(format)", symbol: "paintpalette") { [weak self] in
                        Pasteboard.copy(value)
                        self?.hide()
                        HUD.shared.show("Copied \(value)")
                        return .stay
                    })
                }
            }
        case .text:
            break
        }
        if item.kind != .image && item.kind != .file, let saveSnippet {
            list.append(Action(title: "Save as Snippet", symbol: "text.badge.plus", shortcut: .cmd("s")) { [weak self] in
                self?.hide()
                if saveSnippet(item.text) { HUD.shared.show("Saved as a snippet") } else { HUD.shared.fail("Could not write the snippets file") }
                return .stay
            })
        }
        list.append(Action(title: item.pinned ? "Unpin" : "Pin", symbol: item.pinned ? "pin.slash" : "pin", shortcut: .cmd("p", .shift)) { [weak self] in
            self?.store.togglePin(item.id)
            return .stay
        })
        list.append(Action(title: "Delete", symbol: "trash", shortcut: KeyCombo(key: .character("x"), modifiers: .control), style: .destructive) { [weak self] in
            self?.delete(item)
            return .stay
        })
        list.append(Action(title: "Delete All Unpinned…", symbol: "trash", shortcut: KeyCombo(key: .character("x"), modifiers: [.control, .shift]),
                           style: .destructive) { [weak self] in
            self?.deleteAll()
            return .stay
        })
        return list
    }

    private func run(_ action: Action) {
        closeActionPanel()
        Task { _ = await action.perform() }
    }

    /// Puts an entry on the pasteboard as it was copied (rich text, image, files).
    private func write(_ item: ClipboardItem, plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .image:
            if let data = store.imageData(item) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .file:
            pb.writeObjects((item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        default:
            if !plain, let rtf = store.rtfData(item) { pb.setData(rtf, forType: .rtf) }
            pb.setString(item.text, forType: .string)
        }
        monitor.ignoreCurrentChange()
        store.touch(item.id)
    }

    private func paste(_ item: ClipboardItem, plain: Bool = false) {
        write(item, plain: plain)
        hide()
        guard AXIsProcessTrusted() else {
            HUD.shared.show("Copied. Allow hop in Accessibility to paste", symbol: "exclamationmark.triangle.fill")
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            Pasteboard.postCommandV()
        }
    }

    private func copy(_ item: ClipboardItem) {
        write(item, plain: false)
        hide()
        HUD.shared.show("Copied to Clipboard")
    }

    private func delete(_ item: ClipboardItem) {
        let row = table.selectedRow
        store.delete(item.id)
        reload(keepSelection: false)
        select(firstItemRow(from: min(row, rows.count - 1), step: 1) ?? firstItemRow(from: rows.count - 1, step: -1))
    }

    /// Two presses within four seconds: a lost history can't be brought back.
    private func deleteAll() {
        if let until = deleteAllArmedUntil, until > Date() {
            deleteAllArmedUntil = nil
            let n = store.clear()
            reload(keepSelection: false)
            HUD.shared.show("Deleted \(n) entries", symbol: "trash.fill")
            return
        }
        deleteAllArmedUntil = Date().addingTimeInterval(4)
        updateFooter()
        Task {
            try? await Task.sleep(for: .seconds(4.1))
            updateFooter()
        }
    }

    private func toggleActionPanel() {
        if !actionPanel.isHidden { closeActionPanel(); return }
        guard let item = selectedItem else { return }
        actionPanel.show(actions(for: item))
        actionPanel.onPerform = { [weak self] in self?.run($0) }
        actionPanelHeight.constant = actionPanel.preferredHeight
        actionPanel.isHidden = false
        updateFooter()
    }

    private func closeActionPanel() {
        guard !actionPanel.isHidden else { return }
        actionPanel.isHidden = true
        updateFooter()
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        if !actionPanel.isHidden {
            if event.keyCode == 53 || KeyCombo.cmd("k").matches(event) { closeActionPanel(); return true }
            if actionPanel.handle(event) { return true }
            closeActionPanel()
        }
        switch (event.keyCode, mods) {
        case (53, []): // Esc
            if !query.isEmpty {
                searchField.stringValue = ""
                reload(keepSelection: false)
            } else {
                hide()
            }
            return true
        case (125, []): move(1); return true
        case (126, []): move(-1); return true
        default: break
        }
        if KeyCombo.cmd("k").matches(event) { toggleActionPanel(); return true }
        if KeyCombo.cmd("p").matches(event) { filterPopup.performClick(nil); return true }
        if let item = selectedItem {
            for (i, action) in actions(for: item).enumerated() {
                let combo = i == 0 ? KeyCombo.ret() : action.shortcut
                if let combo, combo.matches(event) { run(action); return true }
            }
        }
        // Editing shortcuts for the search field (no Edit menu in an LSUIElement app).
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

    func controlTextDidChange(_ obj: Notification) { reload(keepSelection: false) }

    @objc private func filterChanged() {
        filter = ClipboardFilter(rawValue: filterPopup.titleOfSelectedItem ?? "") ?? .all
        reload(keepSelection: false)
        panel.makeFirstResponder(searchField)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, case .item(let item) = rows[table.clickedRow] else { return }
        if let first = actions(for: item).first { run(first) }
    }

    // MARK: - Footer

    private func updateFooter() {
        if let until = deleteAllArmedUntil, until > Date() {
            let n = store.items.filter { !$0.pinned }.count
            footer.attributedStringValue = NSAttributedString(string: "Press ⌃⇧X again to delete \(n) unpinned entries", attributes: [
                .font: Theme.meta, .foregroundColor: Theme.destructive,
            ])
            return
        }
        guard let item = selectedItem else {
            footer.attributedStringValue = Keycap.label("Close", keys: "esc")
            return
        }
        let first = config.pasteOnReturn ? "Paste" : "Copy"
        var items: [(String, String)] = [(first, "↵"), (config.pasteOnReturn ? "Copy" : "Paste", "⌘↵"),
                                         (item.pinned ? "Unpin" : "Pin", "⇧⌘P"), ("Delete", "⌃X")]
        let available = (footer.superview?.bounds.width ?? panel.frame.width) - 220
        func build(_ items: [(String, String)]) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (i, (title, keys)) in (items + [("Actions", "⌘K")]).enumerated() {
                if i > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: Theme.meta])) }
                s.append(Keycap.label(title, keys: keys))
            }
            return s
        }
        var text = build(items)
        while !items.isEmpty && text.size().width > available {
            items.removeLast()
            text = build(items)
        }
        footer.attributedStringValue = text
    }

    // MARK: - Preview

    private func updatePreview() {
        guard let item = selectedItem else {
            previewBox.isHidden = true
            return
        }
        previewBox.isHidden = false
        textScroll.isHidden = true
        imageView.isHidden = true
        colorView.isHidden = true
        var info: [(String, String)] = []

        switch item.kind {
        case .image:
            imageView.image = store.imageURL(item).flatMap { NSImage(contentsOf: $0) }
            imageView.isHidden = false
            if let w = item.imageWidth, let h = item.imageHeight { info.append(("Dimensions", "\(w) × \(h)")) }
            info.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)))
        case .color:
            if let c = ClipColor.parse(item.text) {
                colorView.show(c)
                colorView.isHidden = false
            }
        case .file:
            let paths = item.filePaths ?? []
            if paths.count == 1, let img = NSImage(contentsOfFile: paths[0]), img.isValid {
                imageView.image = img
                imageView.isHidden = false
            } else {
                showText(NSAttributedString(string: paths.joined(separator: "\n"), attributes: [
                    .font: Theme.mono(12.5), .foregroundColor: Theme.foreground,
                ]))
            }
            info.append(("Files", "\(paths.count)"))
            if paths.count == 1 {
                info.append(("Path", (paths[0] as NSString).abbreviatingWithTildeInPath))
                if let size = (try? FileManager.default.attributesOfItem(atPath: paths[0]))?[.size] as? Int64 {
                    info.append(("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
                }
            }
        case .link:
            let s = NSMutableAttributedString(string: item.text, attributes: [.font: Theme.mono(14, 500), .foregroundColor: Theme.info])
            if let host = URL(string: item.text)?.host {
                s.append(NSAttributedString(string: "\n\n" + host, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.mutedForeground]))
            }
            showText(s)
        case .text:
            let presentation = ClipboardClassifier.presentation(of: item.text)
            switch presentation {
            case .markdown:
                showText(NotesPreviewView.render(item.text))
            case .code:
                showText(NSAttributedString(string: item.text, attributes: [.font: Theme.mono(12.5), .foregroundColor: Theme.foreground]))
            case .prose:
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 3
                showText(NSAttributedString(string: item.text, attributes: [
                    .font: Theme.sans(14), .foregroundColor: Theme.foreground, .paragraphStyle: p,
                ]))
            }
            let stats = TextStats(item.text)
            let typeName = switch presentation {
            case .markdown: "Markdown"
            case .code: "Code"
            case .prose: item.rtfFile != nil ? "Rich Text" : "Text"
            }
            info.append(("Content type", typeName))
            info.append(("Characters", "\(stats.characters)"))
            info.append(("Words", "\(stats.words)"))
            info.append(("Lines", "\(stats.lines)"))
        }
        if item.kind != .text { info.insert(("Content type", item.kind.label), at: 0) }
        if let source = item.sourceName { info.insert(("Source", source), at: 0) }
        if item.timesCopied > 1 { info.append(("Times copied", "\(item.timesCopied)")) }
        info.append(("Copied", Self.dateFormatter.string(from: item.lastCopied)))
        if item.timesCopied > 1 { info.append(("First copied", Self.dateFormatter.string(from: item.firstCopied))) }
        showInfo(info, sourceBundleID: item.sourceBundleID)
    }

    private func showText(_ text: NSAttributedString) {
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
        textScroll.isHidden = false
    }

    private func showInfo(_ rows: [(String, String)], sourceBundleID: String?) {
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let heading = NSTextField(labelWithAttributedString: Theme.labelString("Information"))
        infoStack.addArrangedSubview(heading)
        for (label, value) in rows {
            let l = NSTextField(labelWithString: label)
            l.font = Theme.sans(12)
            l.textColor = Theme.mutedForeground
            let v = NSTextField(labelWithString: value)
            v.font = Theme.sans(12, 500)
            v.textColor = Theme.foreground
            v.alignment = .right
            v.lineBreakMode = .byTruncatingMiddle
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [l, NSView()]
            if label == "Source", let id = sourceBundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: appURL.path))
                icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
                views.append(icon)
            }
            views.append(v)
            let row = NSStackView(views: views)
            row.spacing = 6
            row.distribution = .fill
            views[1].setContentHuggingPriority(.init(1), for: .horizontal)
            infoStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Theme.border.cgColor
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            infoStack.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 38
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.tint = Palette.clipboard
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let v = tableView.makeView(withIdentifier: SectionHeaderView.identifier, owner: nil) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
            v.configure(title)
            return v
        case .item(let item):
            let v = tableView.makeView(withIdentifier: ResultCellView.identifier, owner: nil) as? ResultCellView
                ?? ResultCellView(frame: .zero)
            v.configure(Item(id: item.id, title: item.title, icon: icon(for: item),
                             accessory: NoteStore.shortAge(item.lastCopied, now: Date()), actions: []))
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
        updateFooter()
    }

    private func icon(for item: ClipboardItem) -> ItemIcon {
        switch item.kind {
        case .image:
            if let thumb = thumbnail(item) { return .image(thumb) }
        case .color:
            if let c = ClipColor.parse(item.text) { return .image(ClipColorView.swatch(c, size: 18)) }
        case .file:
            // Through IconCache: a small bitmap, not a workspace icon redrawn on every reload.
            if let path = item.filePaths?.first { return .file(path) }
        case .link:
            return .symbol("link", tint: Theme.info)
        case .text:
            break
        }
        return .symbol(item.kind.symbol, tint: Theme.mutedForeground)
    }

    private func thumbnail(_ item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails.object(forKey: item.id as NSString) { return cached }
        guard let url = store.imageURL(item), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails.setObject(img, forKey: item.id as NSString)
        return img
    }

    // MARK: - Layout

    private func buildViews() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = panel.frameCornerRadius
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.86).cgColor
        content.layer?.cornerRadius = panel.frameCornerRadius
        glass.contentView = content
        panel.contentView = glass

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Theme.sans(20, 300)
        searchField.textColor = Theme.foreground
        searchField.placeholderAttributedString = NSAttributedString(string: "Search clipboard history", attributes: [
            .font: Theme.sans(20, 300), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.7),
        ])
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false

        filterPopup.addItems(withTitles: ClipboardFilter.allCases.map(\.rawValue))
        filterPopup.font = Theme.sans(12.5, 500)
        filterPopup.controlSize = .small
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [searchField, filterPopup])
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 16)

        let column = NSTableColumn(identifier: .init("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        emptyLabel.font = Theme.body
        emptyLabel.textColor = Theme.mutedForeground

        // Preview: content on top, information below.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [.backgroundColor: Palette.clipboard.withAlphaComponent(0.28)]
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 5
        // The information block keeps its natural height; the content takes the rest and
        // never pushes the window (a big image has a big intrinsic size).
        infoStack.setHuggingPriority(.required, for: .vertical)
        infoStack.setClippingResistancePriority(.required, for: .vertical)
        for v in [textScroll, imageView, colorView] as [NSView] {
            for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                v.setContentHuggingPriority(.init(1), for: o)
                v.setContentCompressionResistancePriority(.init(1), for: o)
            }
        }

        for v in [textScroll, imageView, colorView, infoStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview(v)
        }
        for v in [textScroll, imageView, colorView] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 16),
                v.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 20),
                v.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -20),
                v.bottomAnchor.constraint(equalTo: infoStack.topAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            infoStack.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 20),
            infoStack.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -20),
            infoStack.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -14),
        ])

        let topRule = NSBox()
        topRule.boxType = .separator
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        let midRule = NSView()
        midRule.wantsLayer = true
        midRule.layer?.backgroundColor = Theme.border.cgColor

        footer.lineBreakMode = .byClipping
        actionPanel.isHidden = true

        for v in [header, topRule, listScroll, emptyLabel, midRule, previewBox, bottomRule, countLabel, footer, actionPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        actionPanelHeight = actionPanel.heightAnchor.constraint(equalToConstant: 100)
        let listWidth = listScroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 58),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            listScroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            listWidth,
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            midRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            midRule.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            midRule.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            midRule.widthAnchor.constraint(equalToConstant: 1),
            previewBox.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            previewBox.leadingAnchor.constraint(equalTo: midRule.trailingAnchor),
            previewBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewBox.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 16),
            actionPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            actionPanel.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -6),
            actionPanel.widthAnchor.constraint(equalToConstant: 320),
            actionPanelHeight,
        ])
    }

    #if DEBUG
    func debugSearch(_ text: String) {
        searchField.stringValue = text
        reload(keepSelection: false)
    }

    func debugSelect(_ index: Int) {
        var seen = 0
        for (i, row) in rows.enumerated() {
            guard case .item = row else { continue }
            if seen == index { select(i); return }
            seen += 1
        }
    }

    func debugOpenActions() { toggleActionPanel() }
    #endif
}

/// Big colour swatch with its HEX, RGB and HSL values.
final class ClipColorView: NSView {
    private let swatch = NSView()
    private let values = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 14
        swatch.layer?.borderColor = Theme.border.cgColor
        swatch.layer?.borderWidth = 1
        values.maximumNumberOfLines = 3
        for v in [swatch, values] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.topAnchor.constraint(equalTo: topAnchor),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.trailingAnchor.constraint(equalTo: trailingAnchor),
            swatch.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.6),
            values.topAnchor.constraint(equalTo: swatch.bottomAnchor, constant: 14),
            values.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: ClipColor) {
        swatch.layer?.backgroundColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).cgColor
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        values.attributedStringValue = NSAttributedString(string: [c.hex, c.rgb, c.hsl].joined(separator: "\n"), attributes: [
            .font: Theme.mono(13, 500), .foregroundColor: Theme.foreground, .paragraphStyle: p,
        ])
    }

    /// A small rounded colour square for list rows.
    static func swatch(_ c: ClipColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
