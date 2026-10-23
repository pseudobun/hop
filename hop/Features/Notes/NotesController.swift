import AppKit
import os

/// Floating notes window (⌥.). Non-activating like the launcher, so the app you were
/// in stays frontmost; it floats above other windows until you hide it.
final class NotesPanel: NSPanel {
    /// Sees every keyDown before the text views; return true to consume.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Focus moved (search, editor, preview, find bar); the footer hints follow it.
    var onFocusChange: (() -> Void)?

    /// First-open size; after that the panel keeps the size you leave it at.
    static let defaultSize = NSSize(width: 820, height: 520)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 460, height: 300)
        appearance = Theme.darkAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        onFocusChange?()
        return ok
    }
}

/// Browse, search and edit the Markdown files of a folder (an Obsidian vault) in a
/// floating window. Files are the only storage: every edit is saved back to its `.md`.
final class NotesController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSTextViewDelegate, NSMenuDelegate {
    let panel = NotesPanel()
    var openConfig: (() -> Void)?

    private let settings: AppSettings
    private var config: HopConfig.Notes { settings.data.notes }
    private var root: URL { URL(fileURLWithPath: config.expandedFolder, isDirectory: true) }

    private var notes: [NoteFile] = []
    private var hits: [NoteHit] = []
    private let pins = NotesPins()
    private var contents: [String: (modified: Date, text: String)] = [:]
    private var scanError: String?

    private enum Current { case file(NoteFile), draft }
    private var current: Current?
    private var currentPath: String? { if case .file(let n) = current { n.relativePath } else { nil } }
    /// Disk modification date of the open note when it was last read or written.
    private var loadedModified: Date?
    private var loadedText = ""
    private var dirty = false
    /// The user asked for this draft (↵ in its title), so it is kept even when empty.
    private var draftConfirmed = false
    private var saveTask: Task<Void, Never>?
    private var selectingProgrammatically = false
    /// Back / forward history of relative paths (⌘[ / ⌘]).
    private var back: [String] = []
    private var forward: [String] = []
    /// The note open before the current search started; it enters history when the search is done.
    private var searchOrigin: String?

    private static let frameName = "hop.notes"
    private static let lastNoteKey = "NotesLastNote"
    private static let sidebarHiddenKey = "NotesSidebarHidden"

    // Views
    private let searchField = NSTextField()
    private let table = NSTableView()
    private let sidebar = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private let countLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let metaLabel = NSTextField(labelWithString: "")
    private let textView = NotesTextView.make()
    private let editorScroll = NSScrollView()
    private let preview = NotesPreviewView.make()
    private let previewScroll = NSScrollView()
    private static let previewKey = "NotesPreview"
    private var previewMode: Bool { !previewScroll.isHidden }
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let shortcuts = NotesShortcutsView()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        panel.onFocusChange = { [weak self] in self?.updateFooter() }
        panel.setFrameAutosaveName(Self.frameName)
        textView.onOpenLink = { [weak self] in self?.openLink($0) }
        preview.onOpenLink = { [weak self] in self?.openLink($0) }
        preview.onToggleTask = { [weak self] in self?.toggleTask(at: $0) }
        if UserDefaults.standard.bool(forKey: Self.previewKey) { setPreview(true, focus: false) }
        if UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey) { setSidebar(hidden: true) }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    /// ⌥.: show, focus if visible but in the background, hide if focused.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show(newNote: Bool = false) {
        if !panel.isVisible && UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") == nil {
            centerOnMouseScreen()
        }
        rescan()
        if newNote {
            startDraft(title: "")
        } else if current == nil {
            openInitial()
        } else {
            reloadCurrentIfChangedOnDisk()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        if !newNote { focusEditor() }
    }

    func hide() {
        guard panel.isVisible else { return }
        flush(force: true)
        panel.orderOut(nil)
    }

    /// Writes pending edits now (on quit).
    func saveNow() { flush(force: true) }

    /// The notes folder changed in the config.
    func folderChanged() {
        flush(force: true)
        current = nil
        contents = [:]
        notes = []
        if panel.isVisible { show() }
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let size = NSSize(width: min(NotesPanel.defaultSize.width, v.width - 80),
                          height: min(NotesPanel.defaultSize.height, v.height - 80))
        panel.setFrame(NSRect(x: (v.midX - size.width / 2).rounded(), y: (v.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard current != nil else { return }
        rescan()
        reloadCurrentIfChangedOnDisk()
    }

    func windowDidResignKey(_ notification: Notification) { flush(force: false) }

    func windowDidResize(_ notification: Notification) { updateFooter() }

    // MARK: - Footer hints

    private enum FocusContext { case search, title, find, edit, preview, empty }

    private var focusContext: FocusContext {
        if findBarVisible { return .find }
        if searchFocused { return .search }
        if let editor = titleField.currentEditor(), panel.firstResponder === editor { return .title }
        if current == nil { return .empty }
        return previewMode ? .preview : .edit
    }

    /// The keys that matter where the focus is, most useful first.
    private func hints(_ context: FocusContext) -> [(String, String)] {
        switch context {
        case .search:
            let open: [(String, String)] = hits.isEmpty && !query.isEmpty ? [("Create", "↵")] : [("Open", "↵"), ("Move", "↑↓")]
            return open + [("New note", "⇧↵"), (query.isEmpty ? "Back" : "Clear", "esc")]
        case .title: return [("Start writing", "↵"), ("Close", "esc")]
        case .find: return [("Next", "⌘G"), ("Previous", "⇧⌘G"), ("Close", "esc")]
        case .edit: return [("Notes", "⌘P"), ("Preview", "⌘E"), ("New", "⌘N"), ("Find", "⌘F"), ("Task", "⌘L"),
                            ("Link", "⌥↵"), ("Pin", "⌘D"), ("Back", "⌘["), ("Next", "⌥⌘↓")]
        case .preview: return [("Notes", "⌘P"), ("Edit", "⌘E"), ("Scroll", "↑↓"), ("Find", "⌘F"), ("New", "⌘N"),
                               ("Pin", "⌘D"), ("Back", "⌘["), ("Next", "⌥⌘↓")]
        case .empty: return [("New", "⌘N"), ("Notes", "⌘P")]
        }
    }

    /// Fills the footer with as many hints as fit; "All keys ⌘/" always stays.
    private func updateFooter() {
        let available = (footer.superview?.bounds.width ?? panel.frame.width) - sidebarWidth.constant - 1 - 30 - 16
        var items = hints(focusContext)
        func build(_ items: [(String, String)]) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (i, (title, keys)) in (items + [("All keys", "⌘/")]).enumerated() {
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

    // MARK: - Listing

    private var query: String { searchField.stringValue }

    private func rescan() {
        do {
            notes = try NoteStore.scan(root)
            scanError = nil
        } catch {
            notes = []
            scanError = (error as NSError).localizedFailureReason ?? error.localizedDescription
        }
        loadContents()
        refilter()
        updateMessage()
    }

    /// Reads changed files in the background for full-text search.
    private func loadContents() {
        let stale = notes.filter { !$0.isPlaceholder && contents[$0.relativePath]?.modified != $0.modified }
        guard !stale.isEmpty else { return }
        Task {
            for (note, text) in await Self.readAll(stale) { contents[note.relativePath] = (note.modified, text) }
            if !query.isEmpty { refilter() }
        }
    }

    @concurrent private static func readAll(_ notes: [NoteFile]) async -> [(NoteFile, String)] {
        notes.compactMap { n in NoteStore.read(n.url).map { (n, $0) } }
    }

    @concurrent private static func readCoordinated(_ url: URL) async -> String? {
        NoteStore.readCoordinated(url)
    }

    private func refilter() {
        hits = NoteStore.pinnedFirst(NoteStore.search(notes, query: query, contents: contents.mapValues(\.text),
                                                      sensitivity: settings.data.general.sensitivity),
                                     pinned: pins.paths(in: root), query: query)
        table.reloadData()
        let vault = root.lastPathComponent
        countLabel.attributedStringValue = Theme.labelString(query.isEmpty ? "\(vault) · \(notes.count)" : "\(hits.count) of \(notes.count)")
        selectRow(for: currentPath)
    }

    private func selectRow(for path: String?) {
        selectingProgrammatically = true
        defer { selectingProgrammatically = false }
        guard let path, let i = hits.firstIndex(where: { $0.note.relativePath == path }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    /// Previous / next note in the list; from the search field it previews without history.
    private func moveSelection(_ step: Int, record: Bool = false) {
        guard !hits.isEmpty else { return }
        let next = table.selectedRow < 0 ? (step > 0 ? 0 : hits.count - 1) : max(0, min(hits.count - 1, table.selectedRow + step))
        if record { open(hits[next].note) } else { preview(hits[next].note) }
    }

    /// Opens a note while searching; history gets only the note the search started from.
    private func preview(_ note: NoteFile) {
        if searchOrigin == nil { searchOrigin = currentPath ?? "" }
        open(note, record: false)
    }

    /// The search is over (↵, Tab, Esc): remember where it started.
    private func endSearch() {
        if let origin = searchOrigin, !origin.isEmpty, origin != currentPath { pushHistory(origin) }
        searchOrigin = nil
    }

    private func pushHistory(_ path: String) {
        if back.last != path { back.append(path) }
        if back.count > 50 { back.removeFirst(back.count - 50) }
        forward.removeAll()
    }

    private func goBack(_ forwardDirection: Bool) {
        var from = forwardDirection ? forward : back
        var to = forwardDirection ? back : forward
        while let path = from.popLast() {
            guard let note = notes.first(where: { $0.relativePath == path }) else { continue }
            if let current = currentPath { to.append(current) }
            if forwardDirection { forward = from; back = to } else { back = from; forward = to }
            open(note, record: false)
            focusEditor()
            return
        }
        if forwardDirection { forward = [] } else { back = [] }
    }

    // MARK: - Opening

    private func openInitial() {
        let last = UserDefaults.standard.string(forKey: Self.lastNoteKey)
        if let note = notes.first(where: { $0.relativePath == last }) ?? notes.first {
            open(note)
        } else if scanError == nil {
            startDraft(title: "")
        }
    }

    private func open(_ note: NoteFile, record: Bool = true) {
        if currentPath == note.relativePath { return }
        if record, let previous = currentPath { pushHistory(previous) }
        flush(force: true)
        current = .file(note)
        UserDefaults.standard.set(note.relativePath, forKey: Self.lastNoteKey)
        selectRow(for: note.relativePath)
        guard !note.isPlaceholder else {
            setText("", caretAtBody: false)
            textView.isEditable = false
            updateHeader(meta: "Downloading from iCloud…")
            Task {
                let text = await Self.readCoordinated(note.url)
                guard currentPath == note.relativePath else { return }
                textView.isEditable = true
                rescan()
                current = .file(notes.first { $0.relativePath == note.relativePath } ?? note)
                load(text ?? "", modified: NoteStore.modificationDate(note.url))
            }
            return
        }
        load(NoteStore.read(note.url) ?? "", modified: NoteStore.modificationDate(note.url))
    }

    private func load(_ text: String, modified: Date?) {
        textView.isEditable = true
        setText(text, caretAtBody: true)
        loadedText = text
        loadedModified = modified
        dirty = false
        updateHeader()
    }

    private func setText(_ text: String, caretAtBody: Bool) {
        textView.string = text
        textView.restyle()
        textView.undoManager?.removeAllActions(withTarget: textView)
        let caret = caretAtBody ? NoteStore.frontmatterRange(text).map { NSRange($0, in: text).upperBound } ?? 0
            : (text as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        if previewMode {
            preview.show(text)
            preview.scrollToBeginningOfDocument(nil)
        }
    }

    // MARK: - Preview

    /// ⌘E: rendered reading view ⇄ Markdown source.
    private func setPreview(_ on: Bool, focus: Bool = true) {
        UserDefaults.standard.set(on, forKey: Self.previewKey)
        if editorScroll.isFindBarVisible { finderAction(.hideFindInterface) }
        if on { preview.show(textView.string) }
        previewScroll.isHidden = !on
        editorScroll.isHidden = on || scanError != nil
        updateHeader()
        if focus { focusEditor() }
        updateFooter()
    }

    /// A click on a task box in the preview edits the note (undoable, saved like typing).
    private func toggleTask(at location: Int) {
        let inner = NSRange(location: location + 1, length: 1)
        guard let storage = textView.textStorage, inner.upperBound <= storage.length else { return }
        let replacement = storage.attributedSubstring(from: inner).string == " " ? "x" : " "
        guard textView.shouldChangeText(in: inner, replacementString: replacement) else { return }
        storage.replaceCharacters(in: inner, with: replacement)
        textView.didChangeText()
    }

    private func scrollPreview(by dy: CGFloat) {
        let clip = previewScroll.contentView
        let maxY = max(0, (preview.frame.height) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, clip.bounds.origin.y + dy))))
        previewScroll.reflectScrolledClipView(clip)
    }

    /// Picks up edits made elsewhere (Obsidian, another Mac) while hop had no changes.
    private func reloadCurrentIfChangedOnDisk() {
        guard case .file(let note) = current, !dirty else { return }
        guard FileManager.default.fileExists(atPath: note.url.path) else {
            current = nil
            openInitial()
            return
        }
        let disk = NoteStore.modificationDate(note.url)
        guard disk != loadedModified, let text = NoteStore.read(note.url) else { return }
        let selection = textView.selectedRange()
        load(text, modified: disk)
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func openLink(_ target: String) {
        if target.hasPrefix("note:") {
            let link = String(target.dropFirst(5))
            if let note = NoteStore.resolve(link: link, in: notes) {
                open(note)
                focusEditor()
            } else {
                // Like Obsidian: following a link to a missing page starts it.
                let name = link.split(separator: "|").first.map(String.init) ?? link
                startDraft(title: (name as NSString).lastPathComponent)
            }
        } else if let url = URL(string: target), url.scheme != nil {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInObsidian() {
        flush(force: true)
        guard case .file(let note) = current else { return }
        let path = note.url.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let url = URL(string: "obsidian://open?path=\(path)"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(note.url)
        }
        hide()
    }

    // MARK: - Pin and delete

    private var currentNote: NoteFile? { if case .file(let n) = current { n } else { nil } }

    private func togglePin(_ note: NoteFile) {
        pins.toggle(note.relativePath, in: root)
        let pinned = pins.contains(note.relativePath, in: root)
        refilter()
        HUD.shared.show(pinned ? "Pinned “\(note.title)”" : "Unpinned “\(note.title)”", symbol: pinned ? "pin.fill" : "pin.slash")
    }

    /// Moves a note to the Trash (Finder can put it back); a draft is just dropped.
    private func trashCurrent() {
        if case .draft = current {
            discardDraft()
            openInitial()
            return
        }
        if let note = currentNote { trash(note) }
    }

    private func trash(_ note: NoteFile) {
        let wasOpen = currentPath == note.relativePath
        let index = hits.firstIndex { $0.note.relativePath == note.relativePath }
        if wasOpen {
            flush(force: true) // the Trash gets the latest text
            current = nil
        }
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        } catch {
            if wasOpen { open(note, record: false) }
            HUD.shared.show("Could not move “\(note.title)” to the Trash", symbol: "exclamationmark.triangle.fill")
            return
        }
        pins.remove(note.relativePath, in: root)
        contents[note.relativePath] = nil
        back.removeAll { $0 == note.relativePath }
        forward.removeAll { $0 == note.relativePath }
        rescan()
        if wasOpen {
            if let i = index, !hits.isEmpty { open(hits[min(i, hits.count - 1)].note, record: false) } else { openInitial() }
        }
        HUD.shared.show("Moved “\(note.title)” to the Trash", symbol: "trash.fill")
    }

    /// Right-click on a sidebar row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < hits.count else { return }
        let note = hits[row].note
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            item.representedObject = note.relativePath
            menu.addItem(item)
        }
        let pinned = hits[row].pinned
        add(pinned ? "Unpin" : "Pin to Top", pinned ? "pin.slash" : "pin", #selector(menuTogglePin(_:)))
        add("Show in Finder", "folder", #selector(menuShowInFinder(_:)))
        menu.addItem(.separator())
        add("Move to Trash", "trash", #selector(menuTrash(_:)))
    }

    private func note(for item: NSMenuItem) -> NoteFile? {
        guard let path = item.representedObject as? String else { return nil }
        return notes.first { $0.relativePath == path }
    }

    @objc private func menuTogglePin(_ sender: NSMenuItem) { if let n = note(for: sender) { togglePin(n) } }
    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        if let n = note(for: sender) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
    }
    @objc private func menuTrash(_ sender: NSMenuItem) { if let n = note(for: sender) { trash(n) } }

    // MARK: - New notes

    /// A new note lives only in the editor until it has a title or text; then it is
    /// written to `newNoteFolder`.
    private func startDraft(title: String, confirmed: Bool = false) {
        flush(force: true)
        if previewMode { setPreview(false, focus: false) }
        current = .draft
        draftConfirmed = confirmed
        titleField.stringValue = title
        let text = NoteStore.render(template: config.template, title: title, date: Date())
        setText(text, caretAtBody: false)
        loadedText = text
        loadedModified = nil
        dirty = false
        updateHeader()
        selectRow(for: nil)
        if confirmed {
            materializeDraft(force: false)
            focusEditor()
        } else if title.isEmpty {
            panel.makeFirstResponder(titleField)
        } else {
            focusEditor()
        }
    }

    private func materializeDraft(force: Bool) {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        let text = textView.string
        let body = NoteStore.frontmatterRange(text).map { String(text[$0.upperBound...]) } ?? text
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasBody && !draftConfirmed {
            if force { discardDraft() }
            return
        }
        if typed.isEmpty && !force { return }

        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
            + String(format: "%02d.%02d", Calendar.current.component(.hour, from: Date()), Calendar.current.component(.minute, from: Date()))
        let title = typed.isEmpty ? NoteStore.derivedTitle(text) ?? stamp : typed
        let dir = root.appending(path: config.newNoteFolder, directoryHint: .isDirectory)
        let url = NoteStore.uniqueURL(in: dir, title: title, taken: Set(notes.map { $0.title.lowercased() }))
        let final = NoteStore.setTitle(text, (url.lastPathComponent as NSString).deletingPathExtension)
        do {
            try NoteStore.write(final, to: url)
        } catch {
            updateHeader(meta: "Could not save: \(error.localizedDescription)")
            return
        }
        if final != text {
            let selection = textView.selectedRange()
            let delta = (final as NSString).length - (text as NSString).length
            textView.string = final
            textView.restyle()
            textView.setSelectedRange(NSRange(location: max(0, selection.location + delta), length: 0))
        }
        let rootPath = root.standardizedFileURL.path + "/"
        let note = NoteFile(url: url, relativePath: String(url.standardizedFileURL.path.dropFirst(rootPath.count)),
                            modified: NoteStore.modificationDate(url) ?? Date())
        current = .file(note)
        UserDefaults.standard.set(note.relativePath, forKey: Self.lastNoteKey)
        loadedText = final
        loadedModified = note.modified
        dirty = false
        rescan()
        updateHeader()
    }

    private func discardDraft() {
        current = nil
        textView.string = ""
        dirty = false
    }

    // MARK: - Saving

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NotesTextView === textView else { return }
        dirty = true
        textView.restyle()
        if previewMode { preview.show(textView.string) }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            flush(force: false)
        }
    }

    /// Saves the open note. `force` also writes an untitled draft (on switch, hide, quit).
    private func flush(force: Bool) {
        saveTask?.cancel()
        saveTask = nil
        switch current {
        case .draft:
            materializeDraft(force: force)
        case .file(let note):
            guard dirty else { return }
            var text = textView.string
            if config.bumpUpdated && text != loadedText { text = NoteStore.bumpUpdated(text, date: Date()) }
            keepConflictingCopy(of: note)
            do {
                try NoteStore.write(text, to: note.url)
                loadedText = text
                loadedModified = NoteStore.modificationDate(note.url)
                contents[note.relativePath] = (loadedModified ?? Date(), text)
                dirty = false
                updateHeader()
            } catch {
                updateHeader(meta: "Could not save: \(error.localizedDescription)")
            }
        case nil:
            break
        }
    }

    /// The file changed elsewhere while it had unsaved edits here: keep the other version
    /// next to it before overwriting, the way iCloud names conflicts.
    private func keepConflictingCopy(of note: NoteFile) {
        guard let disk = NoteStore.modificationDate(note.url), let loaded = loadedModified, disk > loaded,
              let theirs = NoteStore.read(note.url), theirs != loadedText else { return }
        let dir = note.url.deletingLastPathComponent()
        let copy = NoteStore.uniqueURL(in: dir, title: "\(note.title) (conflict)", taken: Set(notes.map { $0.title.lowercased() }))
        try? NoteStore.write(theirs, to: copy)
        Log.app.notice("notes: kept conflicting copy \(copy.lastPathComponent, privacy: .public)")
    }

    // MARK: - Header and messages

    private func updateHeader(meta: String? = nil) {
        defer { updateFooter() }
        switch current {
        case .draft:
            folderLabel.attributedStringValue = Theme.labelString("\(config.newNoteFolder.isEmpty ? root.lastPathComponent : config.newNoteFolder) · new", color: Palette.notes)
            titleField.isEditable = true
            titleField.placeholderString = "Untitled"
            metaLabel.stringValue = meta ?? "↵ to start writing · saved as you type"
        case .file(let note):
            let folder = note.folder.isEmpty ? root.lastPathComponent : note.folder.replacingOccurrences(of: "/", with: " / ")
            folderLabel.attributedStringValue = Theme.labelString(folder, color: Palette.notes)
            titleField.isEditable = false
            titleField.stringValue = note.title
            let edited = loadedModified.map { "Edited " + Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
            metaLabel.stringValue = meta ?? (previewMode ? edited + " · Preview, ⌘E to edit" : edited)
        case nil:
            folderLabel.stringValue = ""
            titleField.isEditable = false
            titleField.stringValue = ""
            metaLabel.stringValue = meta ?? ""
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func updateMessage() {
        if let scanError {
            messageLabel.stringValue = """
            Can't open the notes folder
            \(config.folder)

            \(scanError)

            Set notes.folder in ~/.config/hop/config.json5 (⌘, opens it). For a folder in iCloud Drive, \
            allow hop under Privacy & Security › Files and Folders.
            """
        } else if notes.isEmpty && current == nil {
            messageLabel.stringValue = "No notes yet. ⌘N starts one."
        } else {
            messageLabel.stringValue = ""
        }
        messageLabel.isHidden = messageLabel.stringValue.isEmpty
        editorScroll.isHidden = scanError != nil || previewMode
        if scanError != nil { previewScroll.isHidden = true }
    }

    // MARK: - Keys

    private var editorFocused: Bool { panel.firstResponder === textView }
    private var searchFocused: Bool { searchField.currentEditor() != nil && panel.firstResponder === searchField.currentEditor() }

    /// Focuses the note: the editor, or the preview in reading mode.
    private func focusEditor() {
        if previewMode {
            panel.makeFirstResponder(preview)
        } else {
            panel.makeFirstResponder(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private var previewFocused: Bool { previewMode && panel.firstResponder === preview }

    private func focusSearch() {
        if UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey) { setSidebar(hidden: false) }
        if findBarVisible { finderAction(.hideFindInterface) }
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// ⌘F: the native find bar over the note.
    private func findInNote() {
        if !editorFocused && !previewFocused && !findBarVisible { focusEditor() }
        finderAction(.showFindInterface)
    }

    private var findBarVisible: Bool { (previewMode ? previewScroll : editorScroll).isFindBarVisible }

    private func finderAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        (previewMode ? preview : textView).performTextFinderAction(sender)
        DispatchQueue.main.async { [weak self] in self?.updateFooter() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if !shortcuts.isHidden {
            shortcuts.isHidden = true
            return event.keyCode == 53 || (event.keyCode == 44 && mods == .command)
        }
        if event.keyCode == 53 && mods.isEmpty { // Esc steps back: find bar, search text, search, window
            if findBarVisible {
                finderAction(.hideFindInterface)
                focusEditor()
            } else if searchFocused && !query.isEmpty {
                searchField.stringValue = ""
                refilter()
            } else if searchFocused {
                endSearch()
                focusEditor()
            } else {
                hide()
            }
            return true
        }
        if isReturn && searchFocused && mods == .shift { // ⇧↵: new note named after the search
            let title = query.trimmingCharacters(in: .whitespaces)
            searchField.stringValue = ""
            endSearch()
            startDraft(title: title, confirmed: !title.isEmpty)
            return true
        }
        if isReturn && editorFocused && (mods == .option || mods == .command) { // follow the link at the caret
            if let target = textView.linkAtCaret() { openLink(target) }
            return true
        }
        if previewFocused {
            let page = previewScroll.contentView.bounds.height - 60
            switch (event.keyCode, mods) {
            case (125, []): scrollPreview(by: 48); return true // ↓
            case (126, []): scrollPreview(by: -48); return true // ↑
            case (49, []), (121, []): scrollPreview(by: page); return true // Space, Page Down
            case (49, .shift), (116, []): scrollPreview(by: -page); return true // ⇧Space, Page Up
            case (126, .command), (115, []): scrollPreview(by: -.greatestFiniteMagnitude); return true // ⌘↑, Home
            case (125, .command), (119, []): scrollPreview(by: .greatestFiniteMagnitude); return true // ⌘↓, End
            default: break
            }
        }
        guard mods.contains(.command) else { return false }
        switch (event.keyCode, mods) {
        case (42, .command): // ⌘\ (by key position, any layout)
            setSidebar(hidden: !UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey))
            return true
        case (33, .command): goBack(false); return true // ⌘[
        case (30, .command): goBack(true); return true // ⌘]
        case (126, [.command, .option]): moveSelection(-1, record: true); return true // ⌥⌘↑
        case (125, [.command, .option]): moveSelection(1, record: true); return true // ⌥⌘↓
        case (44, .command): shortcuts.isHidden = false; return true // ⌘/
        case (51, [.command, .shift]): trashCurrent(); return true // ⇧⌘⌫
        default: break
        }
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch c {
            case "n": startDraft(title: ""); return true
            case "e": setPreview(!previewMode); return true
            case "p", "o", "k": focusSearch(); return true
            case "f": findInNote(); return true
            case "g": finderAction(.nextMatch); return true
            case "w": hide(); return true
            case "s": flush(force: true); return true
            case "d": if let note = currentNote { togglePin(note) }; return true
            case ",": openConfig?(); return true
            case "l" where editorFocused: textView.toggleTaskOnCurrentLine(); return true
            case "b" where editorFocused: textView.toggleWrap("**"); return true
            case "i" where editorFocused: textView.toggleWrap("*"); return true
            default: break
            }
        }
        if mods == [.command, .shift] {
            switch c {
            case "o": openInObsidian(); return true
            case "g": finderAction(.previousMatch); return true
            default: break
            }
        }
        // Standard editing shortcuts (an LSUIElement app has no Edit menu to route them).
        let selector: Selector? = switch (c, mods) {
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        if let selector { return NSApp.sendAction(selector, to: nil, from: self) }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === searchField {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                endSearch()
                if hits.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let title = query.trimmingCharacters(in: .whitespaces)
                    searchField.stringValue = ""
                    startDraft(title: title, confirmed: true)
                } else {
                    focusEditor()
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                endSearch()
                focusEditor()
                return true
            default: return false
            }
        }
        if control === titleField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if !titleField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { draftConfirmed = true }
                materializeDraft(force: false)
                focusEditor()
                return true
            default: return false
            }
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else { return }
        refilter()
        updateFooter()
        if !query.isEmpty, let first = hits.first { preview(first.note) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 50 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.tint = Palette.notes
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = tableView.makeView(withIdentifier: NoteCellView.identifier, owner: nil) as? NoteCellView ?? NoteCellView(frame: .zero)
        v.configure(hits[row])
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingProgrammatically, table.selectedRow >= 0, table.selectedRow < hits.count else { return }
        open(hits[table.selectedRow].note)
    }

    #if DEBUG
    func debugSearch(_ text: String) {
        focusSearch()
        searchField.stringValue = text
        searchField.currentEditor()?.moveToEndOfDocument(nil)
        refilter()
        if let first = hits.first { open(first.note) }
    }

    func debugShowShortcuts() { shortcuts.isHidden = false }

    func debugType(_ text: String, title: String?) {
        if let title {
            titleField.stringValue = title
            draftConfirmed = true
        }
        focusEditor()
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    #endif

    // MARK: - Layout

    private func setSidebar(hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: Self.sidebarHiddenKey)
        sidebar.isHidden = hidden
        sidebarWidth.constant = hidden ? 0 : 250
        if hidden && searchFocused { focusEditor() }
        updateFooter()
    }

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

        // Sidebar: search, list, count.
        let searchBox = NSView()
        searchBox.wantsLayer = true
        searchBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        searchBox.layer?.cornerRadius = 8
        let glassIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glassIcon.contentTintColor = Theme.mutedForeground
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Theme.sans(14)
        searchField.textColor = Theme.foreground
        searchField.placeholderAttributedString = NSAttributedString(string: "Search notes", attributes: [
            .font: Theme.sans(14), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.7),
        ])
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false

        let column = NSTableColumn(identifier: .init("note"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        table.menu = rowMenu
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay

        let sidebarRule = NSView()
        sidebarRule.wantsLayer = true
        sidebarRule.layer?.backgroundColor = Theme.border.cgColor

        // Editor: folder, title, meta, text, footer.
        folderLabel.lineBreakMode = .byTruncatingMiddle
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = Theme.sans(24, 600)
        titleField.textColor = Theme.foreground
        titleField.isEditable = false
        titleField.isSelectable = true
        titleField.delegate = self
        titleField.cell?.isScrollable = true
        titleField.cell?.wraps = false
        titleField.lineBreakMode = .byTruncatingTail
        metaLabel.font = Theme.meta
        metaLabel.textColor = Theme.mutedForeground
        metaLabel.lineBreakMode = .byTruncatingTail

        textView.delegate = self
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        editorScroll.documentView = textView
        editorScroll.findBarPosition = .aboveContent
        previewScroll.documentView = preview
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.scrollerStyle = .overlay
        previewScroll.findBarPosition = .aboveContent
        previewScroll.isHidden = true
        preview.minSize = NSSize(width: 0, height: 0)
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        messageLabel.font = Theme.body
        messageLabel.textColor = Theme.mutedForeground
        messageLabel.alignment = .center
        messageLabel.isHidden = true

        footer.lineBreakMode = .byClipping
        let footerRule = NSView()
        footerRule.wantsLayer = true
        footerRule.layer?.backgroundColor = Theme.border.cgColor

        for v in [searchBox, glassIcon, searchField, listScroll, countLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        shortcuts.isHidden = true
        for v in [sidebar, sidebarRule, folderLabel, titleField, metaLabel, editorScroll, previewScroll, messageLabel, footerRule, footer, shortcuts] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 250)
        let editorLeading = sidebarRule.trailingAnchor
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,
            searchBox.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            searchBox.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            searchBox.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            searchBox.heightAnchor.constraint(equalToConstant: 32),
            glassIcon.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 10),
            glassIcon.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            glassIcon.widthAnchor.constraint(equalToConstant: 14),
            searchField.leadingAnchor.constraint(equalTo: glassIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            listScroll.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),
            countLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -13),

            sidebarRule.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarRule.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarRule.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRule.widthAnchor.constraint(equalToConstant: 1),

            folderLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            folderLabel.leadingAnchor.constraint(equalTo: editorLeading, constant: 31),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            titleField.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: editorLeading, constant: 29),
            titleField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            metaLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: editorLeading, constant: 31),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            editorScroll.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 8),
            editorScroll.leadingAnchor.constraint(equalTo: editorLeading),
            editorScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            previewScroll.topAnchor.constraint(equalTo: editorScroll.topAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: editorScroll.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: editorScroll.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: editorScroll.bottomAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: editorScroll.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: editorLeading, constant: 40),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -40),
            footerRule.leadingAnchor.constraint(equalTo: editorLeading),
            footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -38),
            footer.leadingAnchor.constraint(equalTo: editorLeading, constant: 30),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -19),
            shortcuts.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            shortcuts.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }
}

/// Sidebar row: title, then folder (or the matching line) and age; a pin in the gutter.
final class NoteCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NoteCell")
    private let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) ?? NSImage())
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Theme.sans(14, 500)
        title.textColor = Theme.foreground
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = Theme.sans(12)
        detail.textColor = Theme.mutedForeground
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        age.font = Theme.mono(11)
        age.textColor = Theme.mutedForeground.withAlphaComponent(0.8)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        pin.contentTintColor = Palette.notes
        pin.isHidden = true
        for v in [pin, title, detail, age] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            pin.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            pin.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -8),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            age.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ hit: NoteHit) {
        pin.isHidden = !hit.pinned
        title.stringValue = hit.note.title
        let where_ = hit.note.folder.isEmpty ? "—" : hit.note.folder
        detail.stringValue = hit.snippet ?? (hit.note.isPlaceholder ? "☁︎ " + where_ : where_)
        detail.textColor = hit.snippet == nil ? Theme.mutedForeground : Theme.foreground.withAlphaComponent(0.75)
        age.stringValue = NoteStore.shortAge(hit.note.modified, now: Date())
    }
}
