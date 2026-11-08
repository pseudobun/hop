import AppKit

/// The Agents panel (⇧⌘Space). It joins every Space while open, so switching Spaces keeps
/// it in view, and it stays up when another app takes focus: Esc (or the hotkey while it
/// has focus) closes it. Non-activating like the launcher.
final class AgentsPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                   styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = NSSize(width: 720, height: 420)
        appearance = Theme.darkAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

/// Sessions on the left (needs you, running, idle, finished), the selected one's latest
/// messages and tool calls on the right; ⌘N starts a new one.
final class AgentsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let panel = AgentsPanel()
    let store = AgentStore()
    private let settings: AppSettings
    private var config: HopConfig.Agents { settings.data.agents }

    private enum Row {
        case header(String)
        case session(AgentSession)
    }

    private var rows: [Row] = []
    private var selectedKey: String?
    /// After starting a session: select it once it shows up.
    private var pendingTmux: String?
    private var stopArmed: (key: String, until: Date)?
    private var detailTask: Task<Void, Never>?
    private var detailShownFor: AgentSession?
    private var ageTimer: Timer?
    private static let frameName = "hop.agents"

    // Views
    private let searchField = NSTextField()
    private let newButton = NSButton()
    private let table = NSTableView()
    private let detailBox = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let chip = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcript = NSTextView()
    private let emptyLabel = NSTextField(labelWithString: "No agent sessions")
    private let countLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let actionPanel = ActionPanelView()
    private var actionPanelHeight: NSLayoutConstraint!
    private let form = AgentSpawnView()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        store.config = { [weak self] in self?.config ?? HopConfig.Agents() }
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        if !panel.setFrameUsingName(Self.frameName) { panel.positionOnMouseScreen() }
        panel.setFrameAutosaveName(Self.frameName)
        store.onChange = { [weak self] in self?.storeChanged() }
        store.onTranscriptChange = { [weak self] key in
            guard let self, key == selectedKey, let s = selectedSession else { return }
            loadDetail(s, delay: 0.25)
        }
        form.onStart = { [weak self] spawn, host in self?.start(spawn, host: host) }
        form.onCancel = { [weak self] in self?.closeForm() }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    /// The hotkey: opens it, focuses it when it is open but another app has the keyboard,
    /// closes it when it already has focus.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show(newSession: Bool = false) {
        panel.level = config.floating ? .floating : .normal
        let wasVisible = panel.isVisible
        if !wasVisible {
            searchField.stringValue = ""
            closeActionPanel()
            if !panel.isOnActiveScreenWithMouse { panel.positionOnMouseScreen() }
            store.start()
            reload()
            startAgeTimer()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        if newSession { openForm() } else if form.isHidden { panel.makeFirstResponder(searchField) }
    }

    func hide() {
        guard panel.isVisible else { return }
        closeActionPanel()
        if !form.isHidden { closeForm() }
        panel.orderOut(nil)
        store.stop()
        ageTimer?.invalidate()
        ageTimer = nil
        detailTask?.cancel()
        detailShownFor = nil
        store.watchedKey = nil
        transcript.textStorage?.setAttributedString(NSAttributedString())
    }

    func windowDidResize(_ notification: Notification) { updateFooter() }

    private func startAgeTimer() {
        ageTimer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAges() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        ageTimer = t
    }

    /// "3m" becomes "4m": reconfigure the visible rows in place.
    private func refreshAges() {
        let visible = table.rows(in: table.visibleRect)
        for r in visible.lowerBound..<min(rows.count, visible.upperBound) {
            if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ResultCellView, case .session(let s) = rows[r] {
                cell.configure(item(for: s))
            }
        }
    }

    // MARK: - Rows

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ s: AgentSession) -> Bool {
        let q = query
        guard !q.isEmpty else { return true }
        let hay = [s.title, s.shortCwd, s.host ?? "this mac", s.provider.label, s.tmux ?? "", s.status.label,
                   s.kind == .remoteControl ? "rc remote control" : "", s.isViewOnly ? "view only" : "", s.needsTrust ? "trust folder" : ""].joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }

    private func storeChanged() {
        reload()
        if let tmux = pendingTmux, let s = store.sessions.first(where: { $0.tmux == tmux && !$0.id.hasPrefix("tmux:") })
            ?? store.sessions.first(where: { $0.tmux == tmux }) {
            selectedKey = s.key
            if !s.id.hasPrefix("tmux:") { pendingTmux = nil }
            reload()
        }
    }

    private func reload() {
        let visible = store.sessions.filter(matches)
        rows = []
        var last: AgentStatus?
        for s in visible {
            if s.status != last {
                rows.append(.header(s.status.label))
                last = s.status
            }
            rows.append(.session(s))
        }
        table.reloadData()
        let target = selectedKey.flatMap { key in rows.firstIndex { if case .session(let s) = $0 { s.key == key } else { false } } }
            ?? firstSessionRow(from: 0, step: 1)
        select(target, scroll: false)
        emptyLabel.isHidden = !visible.isEmpty
        emptyLabel.stringValue = store.sessions.isEmpty ? "No agent sessions. ⌘N starts one" : "No matches"
        var count = "\(visible.count) sessions"
        let busy = store.sessions.filter { $0.status == .waiting }.count
        if busy > 0 { count += " · \(busy) need you" }
        if let (host, error) = store.hostErrors.sorted(by: { $0.key < $1.key }).first { count += " · \(host): \(error)" }
        countLabel.attributedStringValue = Theme.labelString(count, color: store.hostErrors.isEmpty ? Theme.mutedForeground : Theme.warn)
        countLabel.toolTip = store.hostErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private var selectedSession: AgentSession? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .session(let s) = rows[r] else { return nil }
        return s
    }

    private func select(_ row: Int?, scroll: Bool = true) {
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if scroll { table.scrollRowToVisible(row == firstSessionRow(from: 0, step: 1) ? 0 : row) }
        } else {
            table.deselectAll(nil)
        }
        selectionChanged()
    }

    private func firstSessionRow(from start: Int, step: Int) -> Int? {
        var i = start
        while i >= 0 && i < rows.count {
            if case .session = rows[i] { return i }
            i += step
        }
        return nil
    }

    private func move(_ step: Int) {
        let start = table.selectedRow < 0 ? (step > 0 ? 0 : rows.count - 1) : table.selectedRow + step
        if let next = firstSessionRow(from: start, step: step) { select(next) }
    }

    private func selectionChanged() {
        let s = selectedSession
        selectedKey = s?.key ?? selectedKey
        store.watchedKey = s?.key
        stopArmed = nil
        updateHeader(s)
        updateFooter()
        guard let s else {
            detailShownFor = nil
            transcript.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        // Reload the transcript when the session moved on, not on every list refresh.
        if let shown = detailShownFor, shown.key == s.key, shown.lastActivity == s.lastActivity, shown.status == s.status { return }
        loadDetail(s, delay: 0)
    }

    // MARK: - Detail

    private func updateHeader(_ s: AgentSession?) {
        detailBox.isHidden = s == nil || !form.isHidden
        guard let s else { return }
        titleLabel.stringValue = s.title
        var meta = [s.provider.label, s.host ?? "This Mac", s.shortCwd]
        if let m = s.model { meta.append(m) }
        if let t = s.tmux { meta.append("tmux \(t)") }
        else if s.isViewOnly { meta.append(s.kind == .remoteControl ? "Remote Control · view only" : "Not in tmux · view only") }
        metaLabel.stringValue = meta.joined(separator: "  ·  ")
        metaLabel.toolTip = "Session \(s.id)" + (s.remoteID.map { "\nclaude.ai \($0)" } ?? "") + (s.transcript.map { "\n\($0)" } ?? "")
        let c = chipFor(s) ?? Chip(text: "Finished \(AgentNames.age(s.lastActivity, now: Date())) ago", tone: .neutral)
        chip.attributedStringValue = Theme.labelString(c.text, color: c.color)
    }

    private func loadDetail(_ s: AgentSession, delay: Double) {
        detailTask?.cancel()
        let first = detailShownFor?.key != s.key
        if first {
            transcript.textStorage?.setAttributedString(NSAttributedString(string: s.isLocal ? "" : "Loading from \(s.host ?? "")…", attributes: [
                .font: Theme.meta, .foregroundColor: Theme.mutedForeground,
            ]))
        }
        detailShownFor = s
        detailTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard let self, !Task.isCancelled else { return }
            let entries = await store.entries(for: s)
            guard !Task.isCancelled, selectedKey == s.key else { return }
            show(entries, for: s, scrollToEnd: first)
        }
    }

    private func show(_ entries: [TranscriptEntry], for s: AgentSession, scrollToEnd: Bool) {
        let clip = transcriptScroll.contentView
        let atBottom = clip.bounds.maxY >= (transcript.frame.height - 24)
        let empty = s.needsTrust
            ? "Claude Code asks whether you trust \(s.shortCwd) and waits until someone answers: Remote Control starts after that. "
                + "⌘T answers “Yes, I trust this folder”; ⌘↵ attaches a terminal to answer it there."
            : s.id.hasPrefix("tmux:") ? "Starting…" : "No messages yet"
        let text = Self.render(entries, provider: s.provider, empty: empty)
        transcript.textStorage?.setAttributedString(text)
        if scrollToEnd || atBottom { transcript.scrollToEndOfDocument(nil) }
    }

    /// The transcript as styled text: prompts, replies, tool calls with their first result lines.
    static func render(_ entries: [TranscriptEntry], provider: AgentProvider, empty: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard !entries.isEmpty else {
            return NSAttributedString(string: empty, attributes: [.font: Theme.meta, .foregroundColor: Theme.mutedForeground])
        }
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 2
        body.paragraphSpacing = 10
        let tight = NSMutableParagraphStyle()
        tight.paragraphSpacing = 2
        let indented = NSMutableParagraphStyle()
        indented.firstLineHeadIndent = 14
        indented.headIndent = 14
        indented.paragraphSpacing = 8
        func clipped(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        for e in entries {
            switch e.kind {
            case .user:
                out.append(Theme.labelString("You", color: Palette.agents))
                out.append(NSAttributedString(string: "\n" + clipped(e.text, 1200) + "\n", attributes: [
                    .font: Theme.sans(13.5, 500), .foregroundColor: Theme.foreground, .paragraphStyle: body,
                ]))
            case .assistant:
                out.append(Theme.labelString(provider == .claude ? "Claude" : "OpenCode"))
                out.append(NSAttributedString(string: "\n" + clipped(e.text, 2400) + "\n", attributes: [
                    .font: Theme.sans(13.5), .foregroundColor: Theme.foreground.withAlphaComponent(0.92), .paragraphStyle: body,
                ]))
            case .tool(let name):
                out.append(NSAttributedString(string: "→ \(name)", attributes: [
                    .font: Theme.mono(12, 500), .foregroundColor: Theme.info, .paragraphStyle: tight,
                ]))
                out.append(NSAttributedString(string: (e.text.isEmpty ? "" : "  " + clipped(e.text, 200)) + "\n", attributes: [
                    .font: Theme.mono(12), .foregroundColor: Theme.mutedForeground, .paragraphStyle: tight,
                ]))
            case .result(let isError):
                guard !e.text.isEmpty else { continue }
                out.append(NSAttributedString(string: clipped(e.text, 400) + "\n", attributes: [
                    .font: Theme.mono(11.5), .foregroundColor: isError ? Theme.destructive : Theme.mutedForeground.withAlphaComponent(0.75),
                    .paragraphStyle: indented,
                ]))
            case .notice:
                out.append(NSAttributedString(string: "— \(e.text) —\n", attributes: [
                    .font: Theme.mono(11.5), .foregroundColor: Theme.mutedForeground, .paragraphStyle: body,
                ]))
            }
        }
        return out
    }

    // MARK: - Actions

    private func host(_ s: AgentSession) -> HopConfig.Agents.Host? {
        s.host.flatMap { label in config.hosts.first { $0.label == label } }
    }

    private func actions(for s: AgentSession) -> [Action] {
        var list: [Action] = []
        let attach: Action? = s.tmux.map { name in
            Action(title: "Attach in Terminal", symbol: "terminal", shortcut: .ret(.command)) { [weak self] in
                guard let self else { return .stay }
                if let error = AgentLauncher.attach(tmux: name, host: host(s), config: config) { HUD.shared.fail(error) }
                return .stay
            }
        }
        let canResume = s.status == .finished && s.tmux == nil && !s.id.hasPrefix("tmux:")
        let resume: Action? = canResume ? Action(title: "Resume in tmux", symbol: "play.fill", shortcut: .ret(.command)) { [weak self] in
            guard let self else { return .stay }
            let spawn = AgentCommands.Spawn(provider: s.provider, cwd: s.cwd, prompt: "", resume: s.id,
                                            tmuxName: AgentNames.tmuxName(provider: s.provider, cwd: s.cwd, suffix: AgentNames.randomSuffix()))
            start(spawn, host: host(s))
            return .stay
        } : nil
        // A `claude rc` child has no terminal: continuing it in Claude is the main action.
        let primaryWeb = s.kind == .remoteControl && s.isViewOnly
        let web: Action? = s.webURL.map { url in
            Action(title: "Open in Claude", symbol: "safari", shortcut: primaryWeb ? .ret(.command) : .cmd("o")) {
                NSWorkspace.shared.open(url)
                return .stay
            }
        }
        list += (primaryWeb ? [web, attach, resume] : [attach, resume, web]).compactMap { $0 }
        // Claude Code asks whether to trust the folder: answer it here, or attach and answer there.
        if s.needsTrust, let name = s.tmux {
            list.insert(Action(title: "Trust Folder & Start", symbol: "checkmark.shield", shortcut: .cmd("t")) { [weak self] in
                self?.confirmTrust(s, tmux: name)
                return .stay
            }, at: min(1, list.count))
        }
        if s.isLocal, let path = s.transcript {
            list.append(Action(title: "Show Transcript in Finder", symbol: "folder", shortcut: .cmd("f", .shift)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return .stay
            })
        }
        if !s.id.hasPrefix("tmux:") {
            list.append(Action(title: "Copy Session ID", symbol: "number", shortcut: .cmd("c", .shift)) {
                Pasteboard.copy(s.id)
                HUD.shared.show("Copied \(s.id)")
                return .stay
            })
        }
        list.append(Action(title: "Copy Folder Path", symbol: "link", shortcut: .cmd("c", [.option])) {
            Pasteboard.copy(s.cwd)
            HUD.shared.show("Copied \(s.shortCwd)")
            return .stay
        })
        list.append(Action(title: "New Session…", symbol: "plus", shortcut: .cmd("n")) { [weak self] in
            self?.openForm(like: s)
            return .stay
        })
        list.append(Action(title: "Refresh", symbol: "arrow.clockwise", shortcut: .cmd("r")) { [weak self] in
            self?.refreshAll()
            return .stay
        })
        if let name = s.tmux, name.hasPrefix("hop-") {
            list.append(Action(title: "Stop tmux Session…", symbol: "xmark.octagon", shortcut: KeyCombo(key: .character("x"), modifiers: .control),
                               style: .destructive) { [weak self] in
                self?.stop(s, tmux: name)
                return .stay
            })
        }
        return list
    }

    private func run(_ action: Action) {
        closeActionPanel()
        Task { _ = await action.perform() }
    }

    private func refreshAll() {
        store.refresh(force: true)
        store.refreshRemote()
        if let s = selectedSession { loadDetail(s, delay: 0) }
    }

    /// Two presses within four seconds: the agent in it ends.
    private func stop(_ s: AgentSession, tmux name: String) {
        if let armed = stopArmed, armed.key == s.key, armed.until > Date() {
            stopArmed = nil
            Task {
                if let error = await AgentLauncher.stop(tmux: name, host: host(s), config: config) {
                    HUD.shared.fail(error)
                } else {
                    HUD.shared.show("Stopped \(name)", symbol: "xmark.octagon.fill")
                }
                refreshAll()
            }
            updateFooter()
            return
        }
        stopArmed = (s.key, Date().addingTimeInterval(4))
        updateFooter()
        Task {
            try? await Task.sleep(for: .seconds(4.1))
            updateFooter()
        }
    }

    /// "Yes, I trust this folder" in the session's trust question, then a look at the result.
    private func confirmTrust(_ s: AgentSession, tmux name: String) {
        Task {
            if let error = await AgentLauncher.confirmTrust(tmux: name, host: host(s), config: config) {
                HUD.shared.fail(error)
                return
            }
            HUD.shared.show("Trusted \(s.shortCwd)", symbol: "checkmark.shield.fill")
            refreshSoon(remote: s.host != nil)
        }
    }

    /// A couple of refreshes after starting or answering something: Claude Code draws its
    /// trust question, or registers the session, a moment later. Nothing runs once closed.
    private func refreshSoon(remote: Bool) {
        Task {
            for delay in [1.5, 4.0] {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard panel.isVisible else { return }
                if remote { store.refreshRemote() } else { store.refresh(force: true) }
            }
        }
    }

    private func start(_ spawn: AgentCommands.Spawn, host: HopConfig.Agents.Host?) {
        form.isBusy = true
        Task {
            let error = await AgentLauncher.start(spawn, host: host, config: config)
            form.isBusy = false
            if let error {
                HUD.shared.fail(error)
                return
            }
            HUD.shared.show("Started \(spawn.tmuxName)\(host.map { " on \($0.label)" } ?? "")")
            pendingTmux = spawn.tmuxName
            if !form.isHidden { closeForm() }
            store.refresh(force: true)
            refreshSoon(remote: host != nil)
        }
    }

    // MARK: - New session form

    private func openForm(like s: AgentSession? = nil) {
        closeActionPanel()
        let base = s ?? selectedSession
        let hosts = config.hosts.filter { !$0.ssh.isEmpty }
        var providers = AgentProvider.allCases.filter { $0 == .claude ? config.claude.enabled : config.opencode.enabled }
        if providers.isEmpty { providers = [.claude] }
        form.configure(providers: providers, preferred: s?.provider ?? config.defaultProvider, hosts: hosts,
                       host: base?.host, defaultCwd: { [weak self] host in host?.cwd ?? self?.config.defaultCwd ?? "~" },
                       cwd: s?.cwd, projects: { [weak self] host in self?.store.recentProjects(host: host) ?? [] })
        form.isHidden = false
        detailBox.isHidden = true
        form.focus(in: panel)
        updateFooter()
    }

    private func closeForm() {
        form.isHidden = true
        updateHeader(selectedSession)
        panel.makeFirstResponder(searchField)
        updateFooter()
    }

    private func toggleActionPanel() {
        if !actionPanel.isHidden { closeActionPanel(); return }
        guard let s = selectedSession else { return }
        actionPanel.show(actions(for: s))
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
        if !form.isHidden { return form.handleKey(event) || editingShortcut(event, mods) }
        switch (event.keyCode, mods) {
        case (53, []): // Esc
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hide()
            }
            return true
        case (125, []): move(1); return true
        case (126, []): move(-1); return true
        default: break
        }
        if KeyCombo.cmd("k").matches(event) { toggleActionPanel(); return true }
        if KeyCombo.cmd("n").matches(event) { openForm(); return true }
        if KeyCombo.cmd("r").matches(event) { refreshAll(); return true }
        if let s = selectedSession {
            for (i, action) in actions(for: s).enumerated() {
                if i == 0 && KeyCombo.ret().matches(event) { run(action); return true }
                if let combo = action.shortcut, combo.matches(event) { run(action); return true }
            }
        }
        return editingShortcut(event, mods)
    }

    /// Editing shortcuts for the text fields (no Edit menu in an LSUIElement app).
    private func editingShortcut(_ event: NSEvent, _ mods: NSEvent.ModifierFlags) -> Bool {
        guard mods == .command, let c = event.charactersIgnoringModifiers else { return false }
        let selector: Selector? = switch c {
        case "a": #selector(NSText.selectAll(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, case .session(let s) = rows[table.clickedRow] else { return }
        if let first = actions(for: s).first { run(first) }
    }

    @objc private func newClicked() { openForm() }

    // MARK: - Footer

    private func updateFooter() {
        if !form.isHidden {
            footer.attributedStringValue = joined([("Start", "↵"), ("Complete", "tab"), ("Provider", "⌘P"), ("Where", "⌘T"), ("Cancel", "esc")])
            return
        }
        if let armed = stopArmed, armed.until > Date(), let s = selectedSession, s.key == armed.key {
            footer.attributedStringValue = NSAttributedString(string: "Press ⌃X again to stop \(s.tmux ?? "it") and the agent in it", attributes: [
                .font: Theme.meta, .foregroundColor: Theme.destructive,
            ])
            return
        }
        guard let s = selectedSession else {
            footer.attributedStringValue = joined([("New", "⌘N"), ("Close", "esc")])
            return
        }
        let acts = actions(for: s)
        var items: [(String, String)] = []
        if let first = acts.first { items.append((first.title.replacingOccurrences(of: " in Terminal", with: ""), "↵")) }
        if s.needsTrust { items.append(("Trust Folder", "⌘T")) }
        items.append(("New", "⌘N"))
        let available = (footer.superview?.bounds.width ?? panel.frame.width) - 260
        var text = joined(items + [("Actions", "⌘K")])
        while items.count > 1 && text.size().width > available {
            items.removeLast()
            text = joined(items + [("Actions", "⌘K")])
        }
        footer.attributedStringValue = text
    }

    private func joined(_ items: [(String, String)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (i, (title, keys)) in items.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: Theme.meta])) }
            s.append(Keycap.label(title, keys: keys))
        }
        return s
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .session = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.tint = Palette.agents
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let v = tableView.makeView(withIdentifier: SectionHeaderView.identifier, owner: nil) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
            v.configure(title)
            return v
        case .session(let s):
            let v = tableView.makeView(withIdentifier: ResultCellView.identifier, owner: nil) as? ResultCellView
                ?? ResultCellView(frame: .zero)
            v.configure(item(for: s))
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    private func item(for s: AgentSession) -> Item {
        let symbol = s.provider == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right"
        let tint = s.provider == .claude ? Theme.chart2 : Theme.chart3
        var subtitle = s.shortCwd
        if let h = s.host { subtitle = "\(h) · " + subtitle }
        // A long first prompt would push the folder out of the row.
        let title = s.title.count > 34 ? s.title.prefix(33).trimmingCharacters(in: .whitespaces) + "…" : s.title
        return Item(id: s.key, title: title, subtitle: subtitle, icon: .tile(symbol, tint),
                    accessory: [s.accessTag, AgentNames.age(s.lastActivity, now: Date())].compactMap { $0 }.joined(separator: " · "),
                    actions: [], chip: s.needsTrust ? Chip(text: "Trust folder", tone: .warn) : chipFor(s))
    }

    private func chipFor(_ s: AgentSession) -> Chip? {
        switch s.status {
        case .waiting where s.needsTrust: Chip(text: "Needs you · trust folder", tone: .warn)
        case .waiting: Chip(text: s.detail ?? "Needs you", tone: .warn)
        case .running where s.id.hasPrefix("tmux:"): Chip(text: "In tmux", tone: .info)
        case .running: Chip(text: s.detail.map { "Running \($0)" } ?? "Running", tone: .info)
        case .idle: Chip(text: "Idle", tone: .neutral)
        case .finished: s.detail.map { Chip(text: $0, tone: .bad) }
        }
    }

    // MARK: - Layout

    private func buildViews() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = panel.frameCornerRadius
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.88).cgColor
        content.layer?.cornerRadius = panel.frameCornerRadius
        glass.contentView = content
        panel.contentView = glass

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Theme.sans(20, 300)
        searchField.textColor = Theme.foreground
        searchField.placeholderAttributedString = NSAttributedString(string: "Filter agent sessions", attributes: [
            .font: Theme.sans(20, 300), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.7),
        ])
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false

        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.attributedTitle = Keycap.label("New Session", keys: "⌘N")
        newButton.isBordered = false
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [searchField, newButton])
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 18)

        let column = NSTableColumn(identifier: .init("agent"))
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

        titleLabel.font = Theme.sans(17, 500)
        titleLabel.textColor = Theme.foreground
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = Theme.meta
        metaLabel.textColor = Theme.mutedForeground
        metaLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 2, height: 8)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.selectedTextAttributes = [.backgroundColor: Palette.agents.withAlphaComponent(0.28)]
        transcriptScroll.documentView = transcript
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.scrollerStyle = .overlay

        let detailRule = NSView()
        detailRule.wantsLayer = true
        detailRule.layer?.backgroundColor = Theme.border.cgColor
        for v in [titleLabel, chip, metaLabel, detailRule, transcriptScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 22),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            chip.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -22),
            chip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailBox.trailingAnchor, constant: -22),
            detailRule.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 12),
            detailRule.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 22),
            detailRule.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -22),
            detailRule.heightAnchor.constraint(equalToConstant: 1),
            transcriptScroll.topAnchor.constraint(equalTo: detailRule.bottomAnchor, constant: 4),
            transcriptScroll.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 18),
            transcriptScroll.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -14),
            transcriptScroll.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -4),
        ])

        let topRule = NSBox()
        topRule.boxType = .separator
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        let midRule = NSView()
        midRule.wantsLayer = true
        midRule.layer?.backgroundColor = Theme.border.cgColor

        footer.lineBreakMode = .byClipping
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionPanel.isHidden = true
        form.isHidden = true

        for v in [header, topRule, listScroll, emptyLabel, midRule, detailBox, form, bottomRule, countLabel, footer, actionPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        actionPanelHeight = actionPanel.heightAnchor.constraint(equalToConstant: 100)
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
            listScroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42),
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            midRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            midRule.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            midRule.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            midRule.widthAnchor.constraint(equalToConstant: 1),
            detailBox.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            detailBox.leadingAnchor.constraint(equalTo: midRule.trailingAnchor),
            detailBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailBox.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            form.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: midRule.trailingAnchor),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

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
        reload()
    }

    func debugSelect(_ index: Int) {
        var seen = 0
        for (i, row) in rows.enumerated() {
            guard case .session = row else { continue }
            if seen == index { select(i); return }
            seen += 1
        }
    }

    func debugOpenActions() { toggleActionPanel() }

    /// One line per listed session: host, provider, kind, claude.ai id, tmux, access, status, detail, link, title.
    func debugDump() -> String {
        store.sessions.map { s in
            [s.host ?? "local", s.provider.rawValue, s.kind.rawValue, s.remoteID ?? "-", s.tmux ?? "-",
             s.isViewOnly ? "view-only" : (s.isAttachable ? "attachable" : "-"), s.status.label, s.detail ?? "-", s.webURL?.absoluteString ?? "-", s.title]
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// Answers the trust question in a listed hop session, as Trust Folder & Start does.
    /// "name" or "name@host".
    func debugConfirmTrust(_ spec: String) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let tmux = parts[0], host = parts.count > 1 ? parts[1] : nil
        guard let s = store.sessions.first(where: { $0.tmux == tmux && $0.needsTrust && $0.host == host }) else {
            HUD.shared.fail("No trust question in \(tmux)")
            return
        }
        confirmTrust(s, tmux: tmux)
    }

    /// "claude|~/repos/hop|prompt|host": starts a session as the form would, with a fixed tmux name.
    func debugStart(_ spec: String, tmuxName: String) {
        let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2, let provider = AgentProvider(rawValue: p[0]) else { return }
        let host = p.count > 3 ? config.hosts.first { $0.label == p[3] } : nil
        start(AgentCommands.Spawn(provider: provider, cwd: p[1], prompt: p.count > 2 ? p[2] : "", resume: nil, tmuxName: tmuxName), host: host)
    }
    #endif
}

private extension NSWindow {
    /// Whether the window is on the screen the mouse is on (it keeps its place otherwise).
    var isOnActiveScreenWithMouse: Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return true }
        return screen.frame.intersects(frame)
    }
}
