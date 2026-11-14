import AppKit

/// An installed or running app, as the picker lists it.
nonisolated struct InstalledApp: Hashable, Sendable {
    /// The name Finder and the launcher show for it.
    let name: String
    let bundleID: String?
    let url: URL
}

/// Every app the launcher indexes (`AppScanner`, the same folders) plus the running ones. Scanned
/// off the main thread, cached, and scanned again each time a picker opens so new installs show up.
nonisolated final class InstalledApps: @unchecked Sendable {
    static let shared = InstalledApps()

    private let lock = NSLock()
    private var cached: [InstalledApp] = []
    private var scanning = false

    var apps: [InstalledApp] { lock.withLock { cached } }

    /// Rescans; `done` runs on the main thread with the new list.
    @MainActor
    func refresh(_ done: @escaping @MainActor @Sendable ([InstalledApp]) -> Void) {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app -> InstalledApp? in
                guard let name = app.localizedName, let url = app.bundleURL else { return nil }
                return InstalledApp(name: name, bundleID: app.bundleIdentifier, url: url)
            }
        let start = lock.withLock { () -> Bool in
            if scanning { return false }
            scanning = true
            return true
        }
        guard start else { return }
        AppScanner.queue.async { [self] in
            var byKey: [String: InstalledApp] = [:]
            for entry in AppScanner.scanBlocking() where entry.kind == .application {
                let app = InstalledApp(name: entry.name, bundleID: entry.bundleID, url: URL(fileURLWithPath: entry.path))
                byKey[app.bundleID ?? app.url.path] = app
            }
            for app in running where byKey[app.bundleID ?? app.url.path] == nil { byKey[app.bundleID ?? app.url.path] = app }
            let list = byKey.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lock.withLock {
                cached = list
                scanning = false
            }
            Task { @MainActor in done(list) }
        }
    }
}

/// A searchable list of apps in a popover. Click or ↵ picks; with `multiple`, clicks tick several
/// and ↵ or "Add" adds them (nothing ticked: the highlighted one).
final class AppPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// What a pick puts in the field: what the setting matches on.
    nonisolated enum Emit: Sendable {
        case name, bundleID

        func value(_ app: InstalledApp) -> String? {
            switch self {
            case .name: app.name
            case .bundleID: app.bundleID
            }
        }
    }

    private let multiple: Bool
    private let emit: Emit
    private let onPick: ([InstalledApp]) -> Void
    private var all: [InstalledApp] = InstalledApps.shared.apps
    private var shown: [InstalledApp] = []
    private var checked: Set<String> = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private weak var popover: NSPopover?
    private static let iconCache = NSCache<NSURL, NSImage>()

    /// Shows a picker under `view`. `exclude`: values (`emit`) already chosen, left out of the list.
    @discardableResult
    static func show(from view: NSView, multiple: Bool, emit: Emit = .name, exclude: Set<String> = [],
                     _ onPick: @escaping ([InstalledApp]) -> Void) -> NSPopover {
        let picker = AppPicker(multiple: multiple, emit: emit, exclude: exclude, onPick: onPick)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        picker.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        picker.view.window?.makeFirstResponder(picker.search)
        return popover
    }

    /// The small button that opens a picker, for next to a text field.
    static func button(toolTip: String = "Choose an app", _ action: @escaping (NSButton) -> Void) -> NSButton {
        let b = AppPickerButton(action)
        b.bezelStyle = .push
        b.image = NSImage(systemSymbolName: "app.badge.plus", accessibilityDescription: toolTip)
            ?? NSImage(systemSymbolName: "plus.app", accessibilityDescription: toolTip)
        b.imagePosition = .imageOnly
        b.toolTip = toolTip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private let exclude: Set<String>

    private init(multiple: Bool, emit: Emit, exclude: Set<String>, onPick: @escaping ([InstalledApp]) -> Void) {
        self.multiple = multiple
        self.emit = emit
        self.exclude = exclude
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = "Search apps"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filter)

        let column = NSTableColumn(identifier: .init("app"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = multiple
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(commitSelection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: multiple ? "Click to toggle · ↵ adds" : "Click or ↵ picks")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(commitSelection)
        addButton.isHidden = !multiple
        let bottom = NSStackView(views: [hint, addButton])
        bottom.spacing = 8

        let stack = NSStackView(views: [search, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for v in [search, scroll, bottom] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 380)
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = stack
        apply()
        InstalledApps.shared.refresh { [weak self] list in
            self?.all = list
            self?.apply()
        }
    }

    @objc private func filter() { apply() }

    private func apply() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = all.filter { emit.value($0).map { !exclude.contains($0) } ?? false }
        shown = q.isEmpty ? candidates : candidates
            .compactMap { app -> (InstalledApp, Int)? in
                let name = app.name.lowercased()
                if name.hasPrefix(q) { return (app, 0) }
                if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return (app, 1) }
                if name.contains(q) { return (app, 2) }
                if app.bundleID?.lowercased().contains(q) == true { return (app, 3) }
                return nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
            .map(\.0)
        table.reloadData()
        if !shown.isEmpty, !multiple { table.selectRowIndexes([0], byExtendingSelection: false) }
        updateAdd()
    }

    private func updateAdd() {
        addButton.title = checked.isEmpty ? "Add" : "Add \(checked.count)"
        addButton.isEnabled = !checked.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = shown[row]
        let icon = NSImageView()
        let iconKey = app.url as NSURL
        if let cached = Self.iconCache.object(forKey: iconKey) {
            icon.image = cached
        } else {
            let image = NSWorkspace.shared.icon(forFile: app.url.path)
            image.size = NSSize(width: 20, height: 20)
            Self.iconCache.setObject(image, forKey: iconKey)
            icon.image = image
        }
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: app.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var views: [NSView] = [icon, name]
        if multiple {
            let mark = NSImageView(image: NSImage(systemSymbolName: checked.contains(key(app)) ? "checkmark.circle.fill" : "circle",
                                                  accessibilityDescription: nil) ?? NSImage())
            mark.contentTintColor = checked.contains(key(app)) ? .controlAccentColor : .tertiaryLabelColor
            views.insert(mark, at: 0)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        row.toolTip = app.bundleID
        return row
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard shown.indices.contains(row) else { return }
        if multiple {
            toggle(shown[row])
        } else {
            finish([shown[row]])
        }
    }

    /// The value a pick emits; only apps that have one are listed.
    private func key(_ app: InstalledApp) -> String { emit.value(app) ?? "" }

    private func toggle(_ app: InstalledApp) {
        let k = key(app)
        if checked.contains(k) { checked.remove(k) } else { checked.insert(k) }
        if let i = shown.firstIndex(of: app) { table.reloadData(forRowIndexes: [i], columnIndexes: [0]) }
        updateAdd()
    }

    @objc private func commitSelection() {
        if multiple {
            if checked.isEmpty, shown.indices.contains(table.selectedRow) { toggle(shown[table.selectedRow]) }
            finish(all.filter { checked.contains(key($0)) })
        } else if shown.indices.contains(table.selectedRow) {
            finish([shown[table.selectedRow]])
        }
    }

    private func finish(_ apps: [InstalledApp]) {
        guard !apps.isEmpty else { NSSound.beep(); return }
        popover?.close()
        onPick(apps)
    }

    // Arrows and ↵ in the search field drive the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !shown.isEmpty else { return true }
            let down = selector == #selector(NSResponder.moveDown(_:))
            let next = max(0, min(shown.count - 1, table.selectedRow + (down ? 1 : -1)))
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close()
            return true
        default:
            return false
        }
    }
}

/// An NSButton that runs a closure, with itself as the argument.
private final class AppPickerButton: NSButton {
    private let run: (NSButton) -> Void

    init(_ run: @escaping (NSButton) -> Void) {
        self.run = run
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { run(self) }
}
