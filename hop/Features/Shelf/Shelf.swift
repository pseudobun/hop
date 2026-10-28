import AppKit
import QuickLookThumbnailing

/// A shelf's window: floats over other apps on every Space and never activates hop,
/// so the app you drag from or to stays frontmost.
final class ShelfPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Shelf.width, height: 160),
                   styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = Theme.darkAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

/// One shelf: a small floating stack of files, links and text you park while dragging.
/// Drop onto it, drag the whole stack (or single rows) out, AirDrop it.
final class Shelf: NSObject, NSWindowDelegate, NSDraggingSource {
    static let width: CGFloat = 272
    static let rowHeight: CGFloat = 30
    private static let visibleRows = 6

    let panel = ShelfPanel()
    private(set) var items: [ShelfItem] = []
    private(set) var pinned = false
    private var selection: Set<UUID> = []
    private var anchor: UUID?
    /// Opened by a shake or the modifier for the drag in progress; it closes again when
    /// that drag ends somewhere else.
    var awaitingDrop = false

    var onClose: ((Shelf) -> Void)?
    var onChange: (() -> Void)?
    /// Dragged-out items stay on the shelf.
    var keepAfterDragOut: () -> Bool = { false }

    private let dropView = ShelfDropView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pinButton = ShelfIconButton(symbol: "pin")
    private let menuButton = ShelfIconButton(symbol: "ellipsis")
    private let closeButton = ShelfIconButton(symbol: "xmark")
    private let keepZone = ShelfDropZone(symbol: "tray.and.arrow.down", title: "Drop to keep")
    private let airDropZone = ShelfDropZone(symbol: "dot.radiowaves.up.forward", title: "AirDrop")
    private let emptyRow = NSStackView()
    private let tile = ShelfStackTile()
    private let rowsStack = FlippedStackView()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private var thumbnails: [String: NSImage] = [:]

    override init() {
        super.init()
        build()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        reload()
    }

    // MARK: - Content

    var isEmpty: Bool { items.isEmpty }

    /// Adds what is not on the shelf yet; returns how many were new.
    @discardableResult
    func add(_ new: [ShelfItem]) -> Int {
        let fresh = new.filter { n in n.exists && !items.contains { $0.sameContent(as: n) } }
        guard !fresh.isEmpty else { return 0 }
        items += fresh
        awaitingDrop = false
        reload()
        onChange?()
        return fresh.count
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        reload()
        onChange?()
        if items.isEmpty && !pinned { close() }
    }

    func clear() { remove(Set(items.map(\.id))) }

    func setPinned(_ on: Bool) {
        pinned = on
        reload()
    }

    private var selectedItems: [ShelfItem] {
        let picked = items.filter { selection.contains($0.id) }
        return picked.isEmpty ? items : picked
    }

    // MARK: - Show / close

    /// Centres the shelf on `point` (screen coordinates), kept inside that screen.
    func show(at point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var frame = panel.frame
        frame.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        if let v = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, v.minX + 8), v.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, v.minY + 8), v.maxY - frame.height - 8)
        }
        panel.setFrame(frame.integral, display: false)
        panel.orderFrontRegardless()
    }

    private var closed = false

    func close() {
        guard !closed else { return }
        closed = true
        panel.orderOut(nil)
        onClose?(self)
    }

    // MARK: - Layout

    private func build() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = panel.frameCornerRadius
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        dropView.wantsLayer = true
        dropView.layer?.backgroundColor = Theme.background.withAlphaComponent(0.86).cgColor
        dropView.layer?.cornerRadius = panel.frameCornerRadius
        dropView.layer?.borderColor = Theme.info.cgColor
        dropView.shelf = self
        glass.contentView = dropView
        panel.contentView = glass

        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.toolTip = "Pin: the shelf stays open when it is empty"
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        menuButton.toolTip = "Actions"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close (⌥-click clears it)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, pinButton, menuButton, closeButton])
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        header.heightAnchor.constraint(equalToConstant: 34).isActive = true

        emptyRow.addArrangedSubview(keepZone)
        emptyRow.addArrangedSubview(airDropZone)
        emptyRow.distribution = .fillEqually
        emptyRow.spacing = 8
        emptyRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        emptyRow.heightAnchor.constraint(equalToConstant: 104).isActive = true
        airDropZone.isHidden = true

        tile.shelf = self
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        scroll.documentView = rowsStack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        scrollHeight.isActive = true

        let column = NSStackView(views: [header, emptyRow, tile, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        column.setHuggingPriority(.required, for: .vertical)
        column.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            column.topAnchor.constraint(equalTo: dropView.topAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for v in [header, emptyRow, tile, scroll] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        dropView.column = column
    }

    private func reload() {
        items.removeAll { !$0.exists }
        selection = selection.intersection(items.map(\.id))
        let count = items.count
        titleLabel.attributedStringValue = Theme.labelString(count == 0 ? "Shelf" : count == 1 ? "Shelf · 1 item" : "Shelf · \(count) items")
        pinButton.symbol = pinned ? "pin.fill" : "pin"
        pinButton.tint = pinned ? Theme.warn : Theme.mutedForeground
        menuButton.isHidden = items.isEmpty
        emptyRow.isHidden = !items.isEmpty
        tile.isHidden = items.isEmpty
        scroll.isHidden = items.count < 2
        tile.update(items: items, icon: { [weak self] in self?.icon(for: $0, size: 40) })

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if items.count >= 2 {
            for item in items {
                let row = ShelfRowView(item: item, icon: icon(for: item, size: 20), selected: selection.contains(item.id))
                row.shelf = self
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -12).isActive = true
            }
        }
        scrollHeight.constant = CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight
        resizeToFit()
    }

    /// Height follows the content; the top edge stays where it is.
    private func resizeToFit() {
        guard let column = dropView.column else { return }
        dropView.layoutSubtreeIfNeeded()
        let height = column.fittingSize.height
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    // MARK: - Icons

    func icon(for item: ShelfItem, size: CGFloat) -> NSImage {
        switch item.kind {
        case .file:
            if let thumb = thumbnails[item.value] { return thumb }
            requestThumbnail(item.value)
            let icon = NSWorkspace.shared.icon(forFile: item.value)
            icon.size = NSSize(width: size, height: size)
            return icon
        case .link:
            return Self.symbol("link", size: size, color: Theme.chart3)
        case .text:
            return Self.symbol("text.alignleft", size: size, color: Theme.chart2)
        }
    }

    private var requested: Set<String> = []

    /// Image, PDF and video previews in place of the generic document icon.
    private func requestThumbnail(_ path: String) {
        guard !requested.contains(path) else { return }
        requested.insert(path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 80, height: 80),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                self?.thumbnails[path] = image
                self?.reload()
            }
        }
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .medium)
            .applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            Theme.muted.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let s = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            return true
        }
    }

    // MARK: - Dropping in

    /// The drop view asks whether the pointer is over the AirDrop zone.
    func isOverAirDrop(_ point: NSPoint, in view: NSView) -> Bool {
        guard !airDropZone.isHidden else { return false }
        return airDropZone.bounds.contains(airDropZone.convert(point, from: view))
    }

    func dragHover(inside: Bool, overAirDrop: Bool) {
        dropView.layer?.borderWidth = inside && !items.isEmpty ? 1.5 : 0
        airDropZone.isHidden = !(inside && items.isEmpty)
        keepZone.highlighted = inside && !overAirDrop
        airDropZone.highlighted = inside && overAirDrop
    }

    /// Takes a drop; false when there was nothing usable (or it came from this shelf).
    func accept(_ info: NSDraggingInfo, airDrop: Bool) -> Bool {
        if let source = info.draggingSource as? NSView, source.window === panel { return false }
        let pasteboard = info.draggingPasteboard
        var found = ShelfItem.items(from: pasteboard)
        let promises = found.isEmpty
            ? (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
            : []
        if found.isEmpty && promises.isEmpty { return false }
        if airDrop {
            if !promises.isEmpty {
                receive(promises) { [weak self] received in self?.send(received) }
            } else {
                send(found)
            }
            if items.isEmpty && !pinned { close() }
            return true
        }
        found = found.filter(\.exists)
        add(found)
        if !promises.isEmpty { receive(promises) { [weak self] in self?.add($0) } }
        return true
    }

    /// Files promised by apps such as Photos or Mail are written into the shelf folder.
    private func receive(_ promises: [NSFilePromiseReceiver], then done: @escaping ([ShelfItem]) -> Void) {
        let dir = ShelfItem.dropDir.appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = OperationQueue()
        var received: [ShelfItem] = []
        let group = DispatchGroup()
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: dir, operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    if error == nil { received.append(.file(url.path)) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { done(received) }
    }

    // MARK: - Dragging out

    func beginDrag(_ dragged: [ShelfItem], event: NSEvent, from view: NSView) {
        guard !dragged.isEmpty else { return }
        let start = view.convert(event.locationInWindow, from: nil)
        let drags: [NSDraggingItem] = dragged.enumerated().map { i, item in
            let d = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
            let image = icon(for: item, size: 40)
            let offset = CGFloat(min(i, 4)) * 4
            d.setDraggingFrame(NSRect(x: start.x - 20 + offset, y: start.y - 20 - offset, width: 40, height: 40), contents: image)
            return d
        }
        let session = view.beginDraggingSession(with: drags, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
        draggedOut = dragged.map(\.id)
    }

    private var draggedOut: [UUID] = []

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = Set(draggedOut)
        draggedOut = []
        guard operation != [], !keepAfterDragOut() else { return }
        remove(ids)
    }

    // MARK: - Rows

    func rowClicked(_ item: ShelfItem, event: NSEvent) {
        panel.makeKey()
        if event.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if event.modifierFlags.contains(.shift), let anchor, let a = items.firstIndex(where: { $0.id == anchor }),
                  let b = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
        if event.clickCount == 2 { open([item]) }
        updateSelection()
    }

    /// Repaints the rows in place: rebuilding them would end a drag that is starting.
    private func updateSelection() {
        for case let row as ShelfRowView in rowsStack.arrangedSubviews { row.selected = selection.contains(row.item.id) }
    }

    /// Dragging a selected row takes the whole selection along.
    func rowDragged(_ item: ShelfItem, event: NSEvent, view: NSView) {
        let dragged = selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
        beginDrag(dragged, event: event, from: view)
    }

    func tileDragged(event: NSEvent, view: NSView) { beginDrag(items, event: event, from: view) }

    // MARK: - Actions

    private func open(_ list: [ShelfItem]) {
        for item in list {
            switch item.kind {
            case .file: NSWorkspace.shared.open(URL(fileURLWithPath: item.value))
            case .link: if let url = URL(string: item.value) { NSWorkspace.shared.open(url) }
            case .text: copy([item])
            }
        }
    }

    private func quickLook(_ list: [ShelfItem]) {
        let paths = list.filter { $0.kind == .file }.map(\.value)
        guard !paths.isEmpty else { return }
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), arguments: ["-p"] + paths)
    }

    private func copy(_ list: [ShelfItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(list.map(\.pasteboardWriter))
        HUD.shared.show(list.count == 1 ? "Copied" : "Copied \(list.count) items")
    }

    private func copyPaths(_ list: [ShelfItem]) {
        let paths = list.filter { $0.kind == .file }.map(\.value)
        guard !paths.isEmpty else { return }
        Pasteboard.copy(paths.joined(separator: "\n"))
        HUD.shared.show(paths.count == 1 ? "Copied path" : "Copied \(paths.count) paths")
    }

    private func reveal(_ list: [ShelfItem]) {
        let urls = list.filter { $0.kind == .file }.map { URL(fileURLWithPath: $0.value) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func pasteFromClipboard() {
        let n = add(ShelfItem.items(from: .general))
        if n == 0 { HUD.shared.show("Nothing new on the clipboard", symbol: "exclamationmark.triangle.fill") }
    }

    /// AirDrop, the shelf's one instant action.
    func send(_ list: [ShelfItem]) {
        Self.airDrop(list)
    }

    static func airDrop(_ list: [ShelfItem]) {
        let objects = list.map(\.shareObject)
        guard !objects.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: objects) else {
            HUD.shared.show("AirDrop can't send these", symbol: "exclamationmark.triangle.fill")
            return
        }
        NSApp.activate()
        service.perform(withItems: objects)
    }

    @objc private func togglePin() { setPinned(!pinned) }

    @objc private func closeClicked() {
        if NSEvent.modifierFlags.contains(.option) { clear() }
        close()
    }

    private struct MenuEntry {
        let title: String
        let symbol: String
        var key = ""
        var mods: NSEvent.ModifierFlags = []
        let run: () -> Void
    }

    private func menuEntries() -> [MenuEntry?] {
        let list = selectedItems
        let files = list.contains { $0.kind == .file }
        let scope = selection.isEmpty || selection.count == items.count ? "" : " (\(selection.count))"
        var entries: [MenuEntry?] = []
        if files { entries.append(MenuEntry(title: "Quick Look\(scope)", symbol: "eye", key: " ") { [weak self] in self?.quickLook(list) }) }
        entries.append(MenuEntry(title: "AirDrop\(scope)", symbol: "dot.radiowaves.up.forward") { [weak self] in self?.send(list) })
        entries.append(MenuEntry(title: "Open\(scope)", symbol: "arrow.up.forward.app", key: "o", mods: .command) { [weak self] in self?.open(list) })
        entries.append(MenuEntry(title: "Copy\(scope)", symbol: "doc.on.doc", key: "c", mods: .command) { [weak self] in self?.copy(list) })
        if files {
            entries.append(MenuEntry(title: "Copy Path\(scope)", symbol: "link", key: "c", mods: [.command, .shift]) { [weak self] in self?.copyPaths(list) })
            entries.append(MenuEntry(title: "Show in Finder\(scope)", symbol: "folder", key: "\r", mods: .command) { [weak self] in self?.reveal(list) })
        }
        entries.append(MenuEntry(title: "Add from Clipboard", symbol: "doc.on.clipboard", key: "v", mods: .command) { [weak self] in self?.pasteFromClipboard() })
        entries.append(nil)
        entries.append(MenuEntry(title: pinned ? "Unpin Shelf" : "Pin Shelf", symbol: pinned ? "pin.slash" : "pin", key: "p", mods: .command) { [weak self] in self?.togglePin() })
        if !selection.isEmpty && selection.count < items.count {
            entries.append(MenuEntry(title: "Remove from Shelf (\(selection.count))", symbol: "minus.circle", key: "\u{8}") { [weak self] in
                guard let self else { return }
                remove(selection)
            })
        }
        entries.append(MenuEntry(title: "Clear Shelf", symbol: "trash", key: "\u{8}", mods: .command) { [weak self] in self?.clear() })
        entries.append(MenuEntry(title: "Close Shelf", symbol: "xmark", key: "w", mods: .command) { [weak self] in self?.close() })
        return entries
    }

    @objc private func showMenu(_ sender: NSView) {
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = Theme.darkAppearance
        for entry in menuEntries() {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(menuPerform(_:)), keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.mods
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            item.target = self
            item.representedObject = MenuAction(entry.run)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuPerform(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }

    private final class MenuAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, mods) {
        case (53, []): // Esc
            if !selection.isEmpty {
                selection = []
                updateSelection()
            } else if !pinned {
                close()
            }
            return true
        case (49, []): quickLook(selectedItems); return true // Space
        case (51, []), (117, []): // ⌫, ⌦
            if !selection.isEmpty { remove(selection) }
            return true
        case (51, .command): clear(); return true
        case (36, .command), (76, .command): reveal(selectedItems); return true
        case (36, []), (76, []): open(selectedItems); return true
        case (125, []), (126, []): // ↓ ↑
            moveSelection(event.keyCode == 125 ? 1 : -1)
            return true
        default: break
        }
        guard mods == .command || mods == [.command, .shift] else { return false }
        switch (key, mods) {
        case ("a", .command): selection = Set(items.map(\.id)); updateSelection()
        case ("c", .command): copy(selectedItems)
        case ("c", [.command, .shift]): copyPaths(selectedItems)
        case ("v", .command): pasteFromClipboard()
        case ("o", .command): open(selectedItems)
        case ("p", .command): togglePin()
        case ("w", .command): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !items.isEmpty else { return }
        let current = items.lastIndex { selection.contains($0.id) }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
        selection = [items[next].id]
        anchor = items[next].id
        updateSelection()
        if let row = rowsStack.arrangedSubviews[safe: next] { row.scrollToVisible(row.bounds) }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Views

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The whole window takes drops; the shelf decides what to do with them.
final class ShelfDropView: NSView {
    weak var shelf: Shelf?
    weak var column: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    private func overAirDrop(_ info: NSDraggingInfo) -> Bool {
        shelf?.isOverAirDrop(convert(info.draggingLocation, from: nil), in: self) ?? false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let source = sender.draggingSource as? NSView, source.window === window { return [] }
        shelf?.dragHover(inside: true, overAirDrop: overAirDrop(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { shelf?.dragHover(inside: false, overAirDrop: false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { shelf?.dragHover(inside: false, overAirDrop: false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let airDrop = overAirDrop(sender)
        shelf?.dragHover(inside: false, overAirDrop: false)
        return shelf?.accept(sender, airDrop: airDrop) ?? false
    }
}

/// Small borderless symbol button for the header.
final class ShelfIconButton: NSButton {
    var symbol: String { didSet { updateImage() } }
    var tint: NSColor = Theme.mutedForeground { didSet { contentTintColor = tint } }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        contentTintColor = tint
        updateImage()
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Dashed target on an empty shelf: keep, or (while dragging over it) AirDrop.
final class ShelfDropZone: NSView {
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private let symbol: String
    private let title: String

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        if highlighted {
            Theme.info.withAlphaComponent(0.12).setFill()
            path.fill()
        }
        path.lineWidth = 1.2
        path.setLineDash([5, 4], count: 2, phase: 0)
        (highlighted ? Theme.info : Theme.border.withAlphaComponent(0.25)).setStroke()
        path.stroke()

        let color = highlighted ? Theme.info : Theme.mutedForeground
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.init(paletteColors: [color]))
        let label = NSAttributedString(string: title, attributes: [.font: Theme.sans(12.5, 500), .foregroundColor: color])
        let labelSize = label.size()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let total = image.size.height + 8 + labelSize.height
            let top = rect.midY + total / 2
            image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: top - image.size.height,
                                  width: image.size.width, height: image.size.height))
            label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: top - total))
        }
    }
}

/// The stack at the top of a shelf: a pile of the first icons, a count and a summary.
/// Dragging it drags everything on the shelf.
final class ShelfStackTile: NSView {
    weak var shelf: Shelf?
    private var icons: [NSImage] = []
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private var downEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Theme.sans(14, 500)
        title.textColor = Theme.foreground
        title.lineBreakMode = .byTruncatingMiddle
        meta.font = Theme.mono(11)
        meta.textColor = Theme.mutedForeground
        meta.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 76),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Drag to take everything along"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(items: [ShelfItem], icon: (ShelfItem) -> NSImage?) {
        icons = items.prefix(3).compactMap(icon)
        title.stringValue = items.count == 1 ? items[0].title : "\(items.count) items"
        meta.stringValue = Self.summary(items)
        needsDisplay = true
    }

    /// "2 files · 1 link", or for one item its size or length.
    static func summary(_ items: [ShelfItem]) -> String {
        if items.count == 1 { return ShelfRowView.meta(items[0]) }
        let counts = [(ShelfItem.Kind.file, "file", "files"), (.link, "link", "links"), (.text, "text", "texts")]
        return counts.compactMap { kind, one, many in
            let n = items.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }.joined(separator: " · ")
    }

    override func draw(_ dirtyRect: NSRect) {
        let size: CGFloat = 40
        for (i, image) in icons.enumerated().reversed() {
            let offset = CGFloat(i) * 5
            let rect = NSRect(x: 18 + offset, y: (bounds.height - size) / 2 - offset + CGFloat(icons.count - 1) * 2.5,
                              width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.set()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - CGFloat(i) * 0.15)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        downEvent = nil
        shelf?.tileDragged(event: down, view: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = shelf?.buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// One item in the shelf's list: click selects (⌘ / ⇧ extend), drag takes it out.
final class ShelfRowView: NSView {
    weak var shelf: Shelf?
    let item: ShelfItem
    var selected: Bool { didSet { layer?.backgroundColor = selected ? Theme.muted.cgColor : nil } }
    private var downEvent: NSEvent?

    init(item: ShelfItem, icon: NSImage, selected: Bool) {
        self.item = item
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = selected ? Theme.muted.cgColor : nil
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: item.title)
        title.font = Theme.sans(13)
        title.textColor = Theme.foreground
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let meta = NSTextField(labelWithString: Self.meta(item))
        meta.font = Theme.mono(11)
        meta.textColor = Theme.mutedForeground
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [image, title, meta])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Shelf.rowHeight),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = item.kind == .text ? String(item.value.prefix(400)) : item.value
    }

    required init?(coder: NSCoder) { fatalError() }

    /// File size, "link", or the text's length.
    static func meta(_ item: ShelfItem) -> String {
        switch item.kind {
        case .file:
            let url = URL(fileURLWithPath: item.value)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { return "folder" }
            return values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        case .link: return "link"
        case .text: return "\(item.value.count) chars"
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        shelf?.rowClicked(item, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        downEvent = nil
        shelf?.rowDragged(item, event: down, view: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let shelf else { return }
        if !selected { shelf.rowClicked(item, event: event) }
        let menu = shelf.buildMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
