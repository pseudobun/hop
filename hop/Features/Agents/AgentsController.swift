import AppKit

/// The Agents panel (⇧⌘Space) in its floating mode (⌘⇧W): it joins every Space while open,
/// so switching Spaces keeps it in view, and it stays up when another app takes focus: Esc
/// (or the hotkey while it has focus) closes it. Non-activating like the launcher.
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

/// The Agents panel as a regular app window (the default): a plain `NSWindow` with traffic
/// lights, in the Dock and ⌘Tab while open, on the one Space it was put on, so tiling
/// window managers (yabai) manage it like any other window.
final class AgentsWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Agents"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .normal
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 720, height: 420)
        appearance = Theme.darkAppearance
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

/// Sessions on the left (needs you, running, idle, finished), the selected one's latest
/// messages and tool calls on the right; ⌘N starts a new one. Chats hop drives itself
/// (`ChatSessions`) list with them and show as a live chat with a composer (`AgentChatView`).
final class AgentsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let floatingPanel = AgentsPanel()
    private let agentsWindow = AgentsWindow()
    /// A regular window (the default) rather than the floating panel; ⌘⇧W switches.
    private(set) var windowed = UserDefaults.standard.object(forKey: windowedKey) as? Bool ?? true
    /// Whichever of the two is in use; the content moves between them.
    var panel: NSWindow { windowed ? agentsWindow : floatingPanel }
    private var root = NSView()
    let store = AgentStore()
    /// Chats hop drives; they outlive the panel being closed.
    let chats = ChatSessions()
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
    private static let windowFrameName = "hop.agents.window"
    private static let windowedKey = "hop.agents.windowed"
    private static let archivedKey = "hop.agents.archived"
    private static let groupByKey = "hop.agents.groupBy"
    /// Sections of the list (⌘⇧G); remembered.
    private var groupBy = AgentGrouping.GroupBy(rawValue: UserDefaults.standard.string(forKey: groupByKey) ?? "") ?? .status
    /// Quick filters (⌘1…⌘9 environment, ⌥⌘1…⌥⌘4 status); for this run only.
    private var filter = AgentGrouping.Filter()
    private let groupControl = NSSegmentedControl()
    /// Session keys hidden with ⌘⌫; searching "archived" lists them.
    private var archived = Set(UserDefaults.standard.stringArray(forKey: archivedKey) ?? [])
    private var deleteArmed: (key: String, until: Date)?
    private static let pinnedKey = "hop.agents.pinned"
    /// Folders pinned in the new session form (⌘⇧P), as "<host label or local>|<path>", oldest first.
    private var pinned = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
    /// The session whose git changes (⌘D) the detail pane shows instead of its transcript.
    private var changesKey: String?
    private var changesTask: Task<Void, Never>?

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
    private let chatView = AgentChatView()
    /// One line for a herdr agent (`herdr agent prompt`), under the transcript.
    private let promptBar = NSTextField()
    private var promptBarHeight: NSLayoutConstraint!
    private var promptTarget: AgentSession?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        store.config = { [weak self] in self?.config ?? HopConfig.Agents() }
        buildViews()
        for (w, name) in [(floatingPanel as NSWindow, Self.frameName), (agentsWindow, Self.windowFrameName)] {
            w.delegate = self
            if !w.setFrameUsingName(name) { w.positionOnMouseScreen() }
            w.setFrameAutosaveName(name)
        }
        floatingPanel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        agentsWindow.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        panel.contentView = root
        store.onChange = { [weak self] in self?.storeChanged() }
        store.onTranscriptChange = { [weak self] key in
            guard let self, key == selectedKey, let s = selectedSession else { return }
            loadDetail(s, delay: 0.25)
        }
        form.onStart = { [weak self] spawn, host in self?.start(spawn, host: host) }
        form.onStartChat = { [weak self] spawn, host in self?.startChat(spawn, host: host) }
        form.onCancel = { [weak self] in self?.closeForm() }
        chats.onChange = { [weak self] chat, listChanged in self?.chatChanged(chat, listChanged: listChanged) }
        chats.onAttention = { [weak self] chat in self?.chatNeedsYou(chat) }
        chatView.onDecision = { [weak self] id, decision in self?.decide(id, decision) }
        chatView.onFocusChange = { [weak self] in self?.updateFooter() }
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    /// The hotkey. The window: shows it where it was, or hides it when it is open. The
    /// floating panel: opens it, focuses it when another app has the keyboard, closes it
    /// when it already has focus.
    func toggle() {
        if windowed {
            if panel.isVisible { hide() } else { show() }
        } else {
            if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
        }
    }

    func show(newSession: Bool = false) {
        if !windowed { panel.level = config.floating ? .floating : .normal }
        let wasVisible = panel.isVisible
        if !wasVisible {
            searchField.stringValue = ""
            closeActionPanel()
            if !windowed && !panel.isOnActiveScreenWithMouse { panel.positionOnMouseScreen() }
            store.start()
            reload()
            startAgeTimer()
        }
        if windowed {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        if newSession { openForm() } else if form.isHidden { panel.makeFirstResponder(searchField) }
    }

    func hide() {
        guard panel.isVisible else { return }
        closeActionPanel()
        closePromptBar()
        if !form.isHidden { closeForm() }
        panel.orderOut(nil)
        if windowed { NSApp.setActivationPolicy(.accessory) }
        store.stop()
        ageTimer?.invalidate()
        ageTimer = nil
        detailTask?.cancel()
        detailShownFor = nil
        store.watchedKey = nil
        transcript.textStorage?.setAttributedString(NSAttributedString())
        chatView.reset()
    }

    func windowDidResize(_ notification: Notification) { updateFooter() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// ⌘⇧W: regular window ↔ floating panel; the content moves across, each keeps its frame.
    private func toggleWindowed() {
        let on = !windowed
        let responder = panel.firstResponder
        panel.orderOut(nil)
        UserDefaults.standard.set(on, forKey: Self.windowedKey)
        windowed = on
        panel.contentView = root
        updateCorners()
        if !on { NSApp.setActivationPolicy(.accessory) }
        show()
        if let view = responder as? NSView, view.window === panel { panel.makeFirstResponder(view) }
        HUD.shared.show(on ? "Agents: window" : "Agents: floating panel", symbol: on ? "macwindow" : "macwindow.on.rectangle")
    }

    /// The glass follows the corner radius of whichever window holds it.
    private func updateCorners() {
        guard let glass = root as? NSGlassEffectView else { return }
        glass.cornerRadius = panel.frameCornerRadius
        glass.contentView?.layer?.cornerRadius = panel.frameCornerRadius
    }

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
                   s.kind == .remoteControl ? "rc remote control" : "", s.isViewOnly ? "view only" : "", s.needsTrust ? "trust folder" : "",
                   s.herdrPane != nil ? "herdr" : "", s.herdrName ?? "", archived.contains(s.key) ? "archived" : "",
                   s.kind == .chat ? "chat hop" : ""].joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }

    private func storeChanged() {
        reload()
        func started(_ s: AgentSession, _ name: String) -> Bool { s.tmux == name || s.herdrName == name }
        if let tmux = pendingTmux, let s = store.sessions.first(where: { started($0, tmux) && !$0.id.hasPrefix("tmux:") && !$0.id.hasPrefix("herdr:") })
            ?? store.sessions.first(where: { started($0, tmux) }) {
            selectedKey = s.key
            if !s.id.hasPrefix("tmux:") && !s.id.hasPrefix("herdr:") { pendingTmux = nil }
            reload()
        }
    }

    /// Observed sessions and hop's chats, without the observed copy of a chat.
    private var allSessions: [AgentSession] {
        ChatRows.merge(chats: chats.all.map { ($0.row, $0.sessionIDs) }, observed: store.sessions)
    }

    private func reload() {
        let showArchived = query.split(separator: " ").contains("archived")
        let sessions = allSessions
        let visible = sessions.filter { archived.contains($0.key) == showArchived && matches($0) && filter.matches($0) }
        let problems = store.hostErrors.merging(Dictionary(uniqueKeysWithValues: store.herdrNotices.map { ($0.key == "local" ? "This Mac" : $0.key, $0.value) })) { a, b in "\(a); \(b)" }
        rows = []
        for section in AgentGrouping.sections(visible, by: groupBy, hosts: config.hosts.map(\.label)) {
            var title = "\(section.title) · \(section.sessions.count)"
            if groupBy == .environment, let error = problems[section.title] { title += " · \(error)" }
            rows.append(.header(title))
            rows += section.sessions.map { .session($0) }
        }
        table.reloadData()
        let target = selectedKey.flatMap { key in rows.firstIndex { if case .session(let s) = $0 { s.key == key } else { false } } }
            ?? firstSessionRow(from: 0, step: 1)
        select(target, scroll: false)
        emptyLabel.isHidden = !visible.isEmpty
        emptyLabel.stringValue = sessions.isEmpty ? "No agent sessions. ⌘N starts one" : "No matches"
        var count = "\(visible.count) sessions"
        if !filter.isEmpty { count += " · only \(filter.label)" }
        // Counted over every session, whatever the filters show.
        let busy = sessions.filter { $0.status == .waiting }.count
        if busy > 0 { count += " · \(busy) need you" }
        if let (host, error) = problems.sorted(by: { $0.key < $1.key }).first { count += " · \(host): \(error)" }
        countLabel.attributedStringValue = Theme.labelString(count, color: problems.isEmpty ? Theme.mutedForeground : Theme.warn)
        countLabel.toolTip = problems.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
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
        if let t = promptTarget, t.key != s?.key { closePromptBar() }
        if let key = changesKey, key != s?.key {
            changesKey = nil
            changesTask?.cancel()
            detailShownFor = nil
        }
        selectedKey = s?.key ?? selectedKey
        store.watchedKey = s?.key
        stopArmed = nil
        updateHeader(s)
        updateDetailMode(s)
        updateFooter()
        guard let s else {
            detailShownFor = nil
            transcript.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        if changesKey == s.key { return }
        if s.kind == .chat {
            detailTask?.cancel()
            detailShownFor = nil
            if let chat = chats.chat(id: s.id) { chatView.show(chat) }
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
        if s.kind == .chat {
            let chat = chats.chat(id: s.id)
            meta.append(chat?.mode.label ?? "")
            meta.append("hop chat")
            metaLabel.stringValue = meta.joined(separator: "  ·  ")
            metaLabel.toolTip = chat?.backend.sessionID.map { "Session \($0)" } ?? "Starting"
            let c = chipFor(s) ?? Chip(text: chat?.backend.status.label ?? "Ended", tone: .neutral)
            chip.attributedStringValue = Theme.labelString(c.text, color: c.color)
            return
        }
        if let t = s.tmux { meta.append("tmux \(t)") }
        else if let p = s.herdrPane { meta.append("herdr \(s.herdrName ?? p)") }
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
        guard changesKey == nil else { return }
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
                out.append(Theme.labelString(provider.speaker))
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
        if s.kind == .chat, let chat = chats.chat(id: s.id) { return chatActions(s, chat) }
        var list: [Action] = []
        var attach: Action? = s.tmux.map { name in
            Action(title: "Attach in Terminal", symbol: "terminal", shortcut: .ret(.command)) { [weak self] in
                guard let self else { return .stay }
                if let error = AgentLauncher.attach(tmux: name, host: host(s), config: config) { HUD.shared.fail(error) }
                return .stay
            }
        }
        if attach == nil, let pane = s.herdrPane {
            attach = Action(title: "Attach in Terminal", symbol: "terminal", shortcut: .ret(.command)) { [weak self] in
                guard let self else { return .stay }
                if let error = AgentLauncher.attach(herdrPane: pane, host: host(s), config: config) { HUD.shared.fail(error) }
                return .stay
            }
        }
        let canResume = s.status == .finished && s.tmux == nil && s.herdrPane == nil && !s.id.hasPrefix("tmux:") && !s.id.hasPrefix("herdr:")
        let resume: Action? = canResume ? Action(title: "Resume in tmux", symbol: "play.fill", shortcut: .ret(.command)) { [weak self] in
            guard let self else { return .stay }
            let spawn = AgentCommands.Spawn(provider: s.provider, cwd: s.cwd, prompt: "", resume: s.id,
                                            tmuxName: AgentNames.tmuxName(provider: s.provider, cwd: s.cwd, suffix: AgentNames.randomSuffix()),
                                            mode: config.permissionMode)
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
        if ChatRows.canContinue(s) {
            list.append(Action(title: "Continue in Chat", symbol: "bubble.left.and.text.bubble.right", shortcut: .ret([.command, .shift])) { [weak self] in
                self?.continueInChat(s)
                return .stay
            })
        }
        // Claude Code asks whether to trust the folder: answer it here, or attach and answer there.
        if s.needsTrust, s.tmux != nil || s.herdrName != nil {
            list.insert(Action(title: "Trust Folder & Start", symbol: "checkmark.shield", shortcut: .cmd("t")) { [weak self] in
                self?.confirmTrust(s)
                return .stay
            }, at: min(1, list.count))
        }
        // herdr types a line into the agent and submits it; it refuses one that waits on a question.
        if let pane = s.herdrPane, !s.needsTrust, s.status != .finished {
            list.insert(Action(title: "Send Prompt…", symbol: "text.bubble", shortcut: .cmd("p")) { [weak self] in
                self?.openPromptBar(s, pane: pane)
                return .stay
            }, at: min(1, list.count))
        }
        if !s.cwd.isEmpty, !s.isLocal || AgentSpawnView.isGitRepository(s.cwd) {
            list.append(Action(title: changesKey == s.key ? "Refresh Changes" : "Show Changes", symbol: "plus.forwardslash.minus",
                               shortcut: .cmd("d")) { [weak self] in
                self?.showChanges(s)
                return .stay
            })
        }
        if let path = s.transcript, s.isLocal {
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
        list.append(Action(title: windowed ? "Use Floating Panel" : "Open as Window", symbol: "macwindow",
                           shortcut: .cmd("w", .shift)) { [weak self] in
            self?.toggleWindowed()
            return .stay
        })
        let isArchived = archived.contains(s.key)
        list.append(Action(title: isArchived ? "Unarchive" : "Archive", symbol: "archivebox",
                           shortcut: KeyCombo(key: .delete, modifiers: [.command])) { [weak self] in
            self?.setArchived(s, !isArchived)
            return .stay
        })
        if s.isLocal, s.status == .finished, s.provider == .claude, s.transcript != nil {
            list.append(Action(title: "Delete Transcript…", symbol: "trash", shortcut: KeyCombo(key: .delete, modifiers: [.command, .shift]),
                               style: .destructive) { [weak self] in
                self?.delete(s)
                return .stay
            })
        }
        if let name = s.tmux, name.hasPrefix("hop-") {
            list.append(Action(title: "Stop tmux Session…", symbol: "xmark.octagon", shortcut: KeyCombo(key: .character("x"), modifiers: .control),
                               style: .destructive) { [weak self] in
                self?.stop(s, tmux: name)
                return .stay
            })
        } else if s.herdrWorkspace != nil {
            list.append(Action(title: "Close herdr Workspace…", symbol: "xmark.octagon", shortcut: KeyCombo(key: .character("x"), modifiers: .control),
                               style: .destructive) { [weak self] in
                self?.stop(s, tmux: s.herdrName ?? "")
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
        if let s = selectedSession, s.kind != .chat { loadDetail(s, delay: 0) }
    }

    private func setArchived(_ s: AgentSession, _ on: Bool) {
        if on { archived.insert(s.key) } else { archived.remove(s.key) }
        UserDefaults.standard.set(Array(archived), forKey: Self.archivedKey)
        HUD.shared.show(on ? "Archived · search \"archived\" to see it" : "Unarchived", symbol: "archivebox")
        reload()
    }

    /// Two presses within four seconds: the transcript goes to the Trash (recoverable there).
    private func delete(_ s: AgentSession) {
        guard let path = s.transcript else { return }
        if let armed = deleteArmed, armed.key == s.key, armed.until > Date() {
            deleteArmed = nil
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                archived.remove(s.key)
                UserDefaults.standard.set(Array(archived), forKey: Self.archivedKey)
                HUD.shared.show("Moved \(s.title) to Trash", symbol: "trash.fill")
            } catch {
                HUD.shared.fail(error.localizedDescription)
            }
            refreshAll()
            return
        }
        deleteArmed = (s.key, Date().addingTimeInterval(4))
        HUD.shared.show("Press ⌘⇧⌫ again to move the transcript to Trash", symbol: "trash")
    }

    /// Two presses within four seconds: the agent in it ends.
    private func stop(_ s: AgentSession, tmux name: String) {
        if let armed = stopArmed, armed.key == s.key, armed.until > Date() {
            stopArmed = nil
            Task {
                let error = if let ws = s.herdrWorkspace, s.tmux == nil {
                    await AgentLauncher.stop(herdrWorkspace: ws, host: host(s), config: config)
                } else {
                    await AgentLauncher.stop(tmux: name, host: host(s), config: config)
                }
                if let error {
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
    private func confirmTrust(_ s: AgentSession) {
        Task {
            let error: String? = if let name = s.tmux {
                await AgentLauncher.confirmTrust(tmux: name, host: host(s), config: config)
            } else if let name = s.herdrName {
                await AgentLauncher.confirmTrust(herdrAgent: name, host: host(s), config: config)
            } else {
                "No terminal to answer in"
            }
            if let error {
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
            let started = await AgentLauncher.start(spawn, host: host, config: config)
            form.isBusy = false
            if let error = started.error {
                HUD.shared.fail(started.fallback.map { "\($0); tmux: \(error)" } ?? error)
                return
            }
            let where_ = host.map { " on \($0.label)" } ?? ""
            if let why = started.fallback {
                HUD.shared.show("Started \(spawn.tmuxName)\(where_) in tmux: \(why)", symbol: "exclamationmark.triangle.fill", tone: .warning, seconds: 4)
            } else {
                HUD.shared.show("Started \(spawn.tmuxName)\(where_)\(started.herdr ? " in herdr" : "")")
            }
            pendingTmux = spawn.tmuxName
            if !form.isHidden { closeForm() }
            store.refresh(force: true)
            refreshSoon(remote: host != nil)
        }
    }

    // MARK: - Grouping and filters

    /// ⌘⇧G cycles; the pills above the list pick one.
    private func setGroupBy(_ g: AgentGrouping.GroupBy?) {
        let all = AgentGrouping.GroupBy.allCases
        groupBy = g ?? all[((all.firstIndex(of: groupBy) ?? 0) + 1) % all.count]
        UserDefaults.standard.set(groupBy.rawValue, forKey: Self.groupByKey)
        groupControl.selectedSegment = all.firstIndex(of: groupBy) ?? 0
        reload()
    }

    /// ⌘1…⌘9: the nth environment (This Mac first), ⌥⌘1…⌥⌘4: a status; 0 clears it.
    private func setFilter(_ digit: Int, status: Bool) {
        if status {
            let statuses: [AgentStatus] = [.waiting, .running, .idle, .finished]
            filter.status = digit >= 1 && digit <= statuses.count ? statuses[digit - 1] : nil
        } else {
            let envs = AgentGrouping.environments(hosts: config.hosts.map(\.label), sessions: allSessions)
            filter.environment = digit >= 1 && digit <= envs.count ? envs[digit - 1] : nil
        }
        HUD.shared.show(filter.isEmpty ? "All sessions" : "Only \(filter.label)", symbol: "line.3.horizontal.decrease.circle")
        reload()
    }

    @objc private func groupClicked() {
        let all = AgentGrouping.GroupBy.allCases
        setGroupBy(all[max(0, min(all.count - 1, groupControl.selectedSegment))])
    }

    // MARK: - Chats

    private var selectedChat: ChatSession? {
        selectedSession.flatMap { $0.kind == .chat ? chats.chat(id: $0.id) : nil }
    }

    /// The chat view for a chat (unless it shows its changes), the transcript otherwise.
    private func updateDetailMode(_ s: AgentSession?) {
        let chat = s?.kind == .chat && changesKey != s?.key && form.isHidden
        if !chat, chatView.isComposerFocused { panel.makeFirstResponder(searchField) }
        chatView.isHidden = !chat
        transcriptScroll.isHidden = chat
    }

    private func chatChanged(_ chat: ChatSession, listChanged: Bool) {
        guard panel.isVisible else { return }
        if listChanged {
            reload()
        } else if selectedSession?.id == chat.id, changesKey == nil, form.isHidden {
            chatView.show(chat)
        }
    }

    /// An approval while you look elsewhere: a HUD (hop posts no notifications); the count
    /// line counts it with the other sessions that need you.
    private func chatNeedsYou(_ chat: ChatSession) {
        if panel.isVisible, selectedKey == chat.key { return }
        let what = chat.backend.pendingApprovals.first?.title ?? "An approval"
        HUD.shared.show("\(chat.title): \(what) needs you", symbol: "exclamationmark.bubble.fill", tone: .warning, seconds: 5)
    }

    /// Answers the chat's first pending approval (or `id`), when it offers `decision`.
    private func decide(_ id: String? = nil, _ decision: ChatDecision) {
        guard let chat = selectedChat,
              let a = chat.backend.pendingApprovals.first(where: { id == nil || $0.id == id }) else { return }
        guard a.options.contains(decision) else {
            HUD.shared.show("\(decision.label) is not offered here", symbol: "exclamationmark.triangle", tone: .warning)
            return
        }
        chat.backend.respond(approval: a.id, decision: decision)
    }

    private func sendFromComposer(_ chat: ChatSession) {
        guard chatView.composer.isEditable else { return }
        let text = chatView.takeMessage().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.backend.send(text)
    }

    private func focusComposer() {
        guard let chat = selectedChat, chatView.composer.isEditable else {
            if let chat = selectedChat, chat.backend.status == .ended || chat.backend.status == .failed {
                HUD.shared.show("This chat ended · ⌘⇧↵ continues it", symbol: "bubble.left")
            }
            return
        }
        _ = chat
        chatView.focusComposer()
        updateFooter()
    }

    /// Selects a chat that just started and puts the cursor in its composer.
    private func showStarted(_ chat: ChatSession) {
        selectedKey = chat.key
        if !form.isHidden { closeForm() }
        reload()
        focusComposer()
    }

    /// The form's Start with Run in: Chat. A worktree is made first, the chat starts in it.
    private func startChat(_ spawn: AgentCommands.Spawn, host: HopConfig.Agents.Host?) {
        guard let provider = ChatRows.chatProvider(spawn.provider) else { start(spawn, host: host); return }
        form.isBusy = true
        Task {
            var cwd = spawn.cwd
            if spawn.worktree != nil {
                switch await AgentLauncher.makeWorktree(spawn, host: host, config: config) {
                case .success(let path): cwd = path
                case .failure(let f):
                    form.isBusy = false
                    HUD.shared.fail(f.text)
                    return
                }
            }
            form.isBusy = false
            let chat = chats.start(provider: provider, cwd: cwd, host: host, mode: spawn.mode,
                                   prompt: spawn.prompt, config: { [weak self] in self?.config ?? HopConfig.Agents() })
            showStarted(chat)
        }
    }

    /// Continue in Chat: resumes a Claude Code or Codex session as a chat, its transcript above.
    private func continueInChat(_ s: AgentSession) {
        guard let provider = ChatRows.chatProvider(s.provider) else { return }
        let chat = chats.start(provider: provider, cwd: s.cwd, host: host(s), mode: config.permissionMode,
                               resume: s.id, title: s.title, config: { [weak self] in self?.config ?? HopConfig.Agents() })
        showStarted(chat)
        Task { [weak self] in
            guard let self else { return }
            let entries = await store.entries(for: s)
            chat.history = entries
            chats.touch(chat)
        }
    }

    /// An ended chat goes on in a new one; its rows become the history.
    private func continueChat(_ old: ChatSession) {
        guard let id = old.backend.sessionID, let provider = ChatRows.chatProvider(old.provider) else { return }
        let chat = chats.start(provider: provider, cwd: old.cwd, host: old.host, mode: old.mode,
                               resume: id, title: old.title, config: { [weak self] in self?.config ?? HopConfig.Agents() })
        chat.history = old.history + old.backend.items.filter { $0.kind != .approval }.map(\.transcriptEntry)
        chats.remove(old)
        showStarted(chat)
    }

    /// Two presses of ⌃X within four seconds: the agent ends, the chat stays listed.
    private func stopChat(_ s: AgentSession, _ chat: ChatSession) {
        if let armed = stopArmed, armed.key == s.key, armed.until > Date() {
            stopArmed = nil
            chats.stop(chat)
            HUD.shared.show("Stopped \(chat.title)", symbol: "xmark.octagon.fill")
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

    private func chatActions(_ s: AgentSession, _ chat: ChatSession) -> [Action] {
        var list: [Action] = []
        let status = chat.backend.status
        let ended = status == .ended || status == .failed
        if ended {
            if chat.backend.sessionID != nil {
                list.append(Action(title: "Continue in Chat", symbol: "bubble.left.and.text.bubble.right", shortcut: .ret([.command, .shift])) { [weak self] in
                    self?.continueChat(chat)
                    return .stay
                })
            }
        } else {
            list.append(Action(title: "Reply", symbol: "text.bubble", shortcut: .cmd("l")) { [weak self] in
                self?.focusComposer()
                return .stay
            })
        }
        if let a = chat.backend.pendingApprovals.first {
            for (d, combo) in [(ChatDecision.allow, KeyCombo.cmd("y")), (.allowAlways, .cmd("y", .shift)), (.deny, .cmd("n", .shift))]
            where a.options.contains(d) {
                list.append(Action(title: "\(d.label): \(a.title)", symbol: d == .deny ? "hand.raised" : "checkmark.circle", shortcut: combo) { [weak self] in
                    self?.decide(a.id, d)
                    return .stay
                })
            }
        }
        if status == .running || status == .waitingForApproval {
            list.append(Action(title: "Interrupt", symbol: "stop.circle", shortcut: .cmd(".")) {
                chat.backend.interrupt()
                return .stay
            })
        }
        if !s.cwd.isEmpty, !s.isLocal || AgentSpawnView.isGitRepository(s.cwd) {
            list.append(Action(title: changesKey == s.key ? "Refresh Changes" : "Show Changes", symbol: "plus.forwardslash.minus",
                               shortcut: .cmd("d")) { [weak self] in
                self?.showChanges(s)
                return .stay
            })
        }
        if let id = chat.backend.sessionID {
            list.append(Action(title: "Copy Session ID", symbol: "number", shortcut: .cmd("c", .shift)) {
                Pasteboard.copy(id)
                HUD.shared.show("Copied \(id)")
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
        list.append(Action(title: windowed ? "Use Floating Panel" : "Open as Window", symbol: "macwindow",
                           shortcut: .cmd("w", .shift)) { [weak self] in
            self?.toggleWindowed()
            return .stay
        })
        let isArchived = archived.contains(s.key)
        list.append(Action(title: isArchived ? "Unarchive" : "Archive", symbol: "archivebox",
                           shortcut: KeyCombo(key: .delete, modifiers: [.command])) { [weak self] in
            self?.setArchived(s, !isArchived)
            return .stay
        })
        if ended {
            list.append(Action(title: "Remove Chat", symbol: "trash", shortcut: KeyCombo(key: .delete, modifiers: [.command, .shift]),
                               style: .destructive) { [weak self] in
                self?.chats.remove(chat)
                return .stay
            })
        } else {
            list.append(Action(title: "Stop Chat…", symbol: "xmark.octagon", shortcut: KeyCombo(key: .character("x"), modifiers: .control),
                               style: .destructive) { [weak self] in
                self?.stopChat(s, chat)
                return .stay
            })
        }
        return list
    }

    /// Keys while a chat is selected: the composer's own (↵ sends, Tab / Esc / ⌘L back to the
    /// list, ⌃C interrupts), the approval answers, Tab or ⌘L from the list into the composer.
    /// nil: not a chat key, the list handles it.
    private func handleChatKey(_ event: NSEvent, _ chat: ChatSession, _ mods: NSEvent.ModifierFlags) -> Bool? {
        guard changesKey == nil else { return nil }
        let editing = chatView.isComposerFocused
        let key = ChatComposerKey.action(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        if editing {
            switch key {
            case .send: sendFromComposer(chat); return true
            case .newline: return false
            case .leave: panel.makeFirstResponder(searchField); updateFooter(); return true
            case .interrupt: chat.backend.interrupt(); return true
            case nil: break
            }
        } else {
            if (event.keyCode == 48 && mods.isEmpty) || KeyCombo.cmd("l").matches(event) { focusComposer(); return true }
            if key == .interrupt { chat.backend.interrupt(); return true }
        }
        if KeyCombo.cmd("y").matches(event) { decide(nil, .allow); return true }
        if KeyCombo.cmd("y", .shift).matches(event) { decide(nil, .allowAlways); return true }
        if KeyCombo.cmd("n", .shift).matches(event) { decide(nil, .deny); return true }
        guard editing else { return nil }
        if KeyCombo.cmd("k").matches(event) { toggleActionPanel(); return true }
        if KeyCombo.cmd("n").matches(event) { openForm(); return true }
        if KeyCombo.cmd("w", .shift).matches(event) { toggleWindowed(); return true }
        if let s = selectedSession {
            for action in chatActions(s, chat) where action.shortcut?.key == .character("x") || action.shortcut == .cmd("d") {
                if let combo = action.shortcut, combo.matches(event) { run(action); return true }
            }
        }
        return editingShortcut(event, mods)
    }

    private func chatFooter(_ chat: ChatSession) -> [(String, String)] {
        var items: [(String, String)] = []
        let status = chat.backend.status
        let ended = status == .ended || status == .failed
        if chatView.isComposerFocused {
            items += [("Send", "↵"), ("New line", "⇧↵")]
        } else if ended {
            if chat.backend.sessionID != nil { items.append(("Continue", "⌘⇧↵")) }
        } else {
            items.append(("Reply", "tab"))
        }
        if let a = chat.backend.pendingApprovals.first {
            items.append(("Allow", "⌘Y"))
            if a.options.contains(.allowAlways) { items.append(("Always", "⌘⇧Y")) }
            items.append(("Deny", "⌘⇧N"))
        }
        if status == .running || status == .waitingForApproval { items.append(("Interrupt", "⌃C")) }
        items.append(chatView.isComposerFocused ? ("List", "esc") : ("New", "⌘N"))
        return items
    }

    /// Footer items that fit, dropping from the end; Actions stays.
    private func fitted(_ items: [(String, String)]) -> NSAttributedString {
        var items = items
        let available = (footer.superview?.bounds.width ?? panel.frame.width) - 260
        var text = joined(items + [("Actions", "⌘K")])
        while items.count > 1 && text.size().width > available {
            items.removeLast()
            text = joined(items + [("Actions", "⌘K")])
        }
        return text
    }

    // MARK: - Changes

    /// `git status` and the diff of the session's folder in the detail pane; Esc goes back.
    private func showChanges(_ s: AgentSession) {
        let refreshing = changesKey == s.key
        changesKey = s.key
        detailTask?.cancel()
        changesTask?.cancel()
        if !refreshing {
            transcript.textStorage?.setAttributedString(NSAttributedString(string: "Reading changes in \(s.shortCwd)\(s.host.map { " on \($0)" } ?? "")…",
                                                                           attributes: [.font: Theme.meta, .foregroundColor: Theme.mutedForeground]))
        }
        detailShownFor = nil
        updateDetailMode(s)
        updateFooter()
        changesTask = Task { [weak self] in
            guard let self else { return }
            let result = await AgentLauncher.changes(cwd: s.cwd, host: host(s))
            guard !Task.isCancelled, changesKey == s.key else { return }
            switch result {
            case .success(let changes):
                transcript.textStorage?.setAttributedString(changes.rendered(cwd: s.shortCwd))
            case .failure(let f):
                transcript.textStorage?.setAttributedString(NSAttributedString(string: "No changes to show: \(f.text)", attributes: [
                    .font: Theme.meta, .foregroundColor: Theme.destructive,
                ]))
            }
            transcript.scrollToBeginningOfDocument(nil)
        }
    }

    private func closeChanges() {
        changesKey = nil
        changesTask?.cancel()
        detailShownFor = nil
        selectionChanged()
    }

    // MARK: - Pinned projects

    private func pinKey(_ path: String, _ host: HopConfig.Agents.Host?) -> String { "\(host?.label ?? "local")|\(path)" }

    private func pinnedProjects(_ host: HopConfig.Agents.Host?) -> [String] {
        let prefix = "\(host?.label ?? "local")|"
        return pinned.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func togglePin(_ path: String, _ host: HopConfig.Agents.Host?) {
        let key = pinKey(path, host)
        if let i = pinned.firstIndex(of: key) { pinned.remove(at: i) } else { pinned.append(key) }
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    // MARK: - Quick prompt (herdr)

    private func openPromptBar(_ s: AgentSession, pane: String) {
        closeActionPanel()
        promptTarget = s
        promptBar.stringValue = ""
        promptBar.placeholderAttributedString = NSAttributedString(string: "Prompt for \(s.herdrName ?? s.title) · ↵ sends · esc cancels", attributes: [
            .font: Theme.sans(13.5), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.7),
        ])
        promptBar.isHidden = false
        promptBarHeight.constant = 32
        panel.makeFirstResponder(promptBar)
        updateFooter()
    }

    private func closePromptBar() {
        guard !promptBar.isHidden else { return }
        promptBar.isHidden = true
        promptBarHeight.constant = 0
        promptTarget = nil
        panel.makeFirstResponder(searchField)
        updateFooter()
    }

    private func sendPrompt() {
        let text = promptBar.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = promptTarget, let pane = s.herdrPane, !text.isEmpty else { return }
        closePromptBar()
        Task {
            if let error = await AgentLauncher.prompt(pane: pane, text: text, host: host(s), config: config) {
                HUD.shared.fail(error)
            } else {
                HUD.shared.show("Sent to \(s.herdrName ?? s.title)", symbol: "text.bubble.fill")
            }
        }
    }

    private var editingPrompt: Bool {
        !promptBar.isHidden && (panel.firstResponder as? NSTextView)?.delegate === promptBar
    }

    // MARK: - New session form

    private func openForm(like s: AgentSession? = nil) {
        closeActionPanel()
        let base = s ?? selectedSession
        let hosts = config.hosts.filter { !$0.ssh.isEmpty }
        // Cursor is not listed anywhere, so it is offered only where it can run: installed here, or a host to try.
        var providers = AgentProvider.allCases.filter {
            config.isEnabled($0) && ($0 != .cursor || !hosts.isEmpty || AgentTools.binary(.cursor, config) != nil)
        }
        if providers.isEmpty { providers = [.claude] }
        form.configure(providers: providers, preferred: s?.provider ?? config.defaultProvider, hosts: hosts,
                       host: base?.host, defaultCwd: { [weak self] host in host?.cwd ?? self?.config.defaultCwd ?? "~" },
                       cwd: s?.cwd, projects: { [weak self] host in
                           guard let self else { return [] }
                           let pins = pinnedProjects(host)
                           return pins + store.recentProjects(host: host).filter { !pins.contains($0) }
                       },
                       multiplexer: { [weak self] host in self?.config.multiplexer(for: host) ?? .tmux },
                       mode: config.permissionMode,
                       runIn: config.runIn,
                       isPinned: { [weak self] path, host in self?.pinnedProjects(host).contains(path) ?? false },
                       togglePin: { [weak self] path, host in self?.togglePin(path, host) })
        form.isHidden = false
        detailBox.isHidden = true
        updateDetailMode(nil)
        form.focus(in: panel)
        updateFooter()
    }

    private func closeForm() {
        form.isHidden = true
        updateHeader(selectedSession)
        panel.makeFirstResponder(searchField)
        chatView.reset()
        selectionChanged()
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
        if let chat = selectedChat, let handled = handleChatKey(event, chat, mods) { return handled }
        if !promptBar.isHidden {
            if event.keyCode == 53 { closePromptBar(); return true }
            if editingPrompt {
                if KeyCombo.ret().matches(event) { sendPrompt(); return true }
                return editingShortcut(event, mods)
            }
        }
        switch (event.keyCode, mods) {
        case (53, []): // Esc
            if changesKey != nil {
                closeChanges()
            } else if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else if !windowed {
                // The window closes with its close button or the hotkey only.
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
        if KeyCombo.cmd("g", .shift).matches(event) { setGroupBy(nil); return true }
        if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), mods == .command || mods == [.command, .option] {
            setFilter(digit, status: mods.contains(.option))
            return true
        }
        if KeyCombo.cmd("w", .shift).matches(event) { toggleWindowed(); return true }
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

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === promptBar { return }
        reload()
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, case .session(let s) = rows[table.clickedRow] else { return }
        if let first = actions(for: s).first { run(first) }
    }

    @objc private func newClicked() { openForm() }

    // MARK: - Footer

    private func updateFooter() {
        if !form.isHidden {
            footer.attributedStringValue = joined([("Start", "↵"), ("Provider", "⌘P"), ("Where", "⌘T"), ("Mode", "⌘M"), ("Run in", "⌘E"), ("Worktree", "⌘G"),
                                                   ("Pin", "⌘⇧P"), ("Cancel", "esc")])
            return
        }
        if !promptBar.isHidden {
            footer.attributedStringValue = joined([("Send", "↵"), ("Cancel", "esc")])
            return
        }
        if let armed = stopArmed, armed.until > Date(), let s = selectedSession, s.key == armed.key {
            let what = s.kind == .chat ? "the chat" : s.tmux ?? s.herdrName.map { "herdr workspace \($0)" } ?? "it"
            footer.attributedStringValue = NSAttributedString(string: "Press ⌃X again to stop \(what) and the agent in it", attributes: [
                .font: Theme.meta, .foregroundColor: Theme.destructive,
            ])
            return
        }
        guard let s = selectedSession else {
            footer.attributedStringValue = joined(windowed ? [("New", "⌘N")] : [("New", "⌘N"), ("Close", "esc")])
            return
        }
        if changesKey == s.key {
            footer.attributedStringValue = joined([("Refresh", "⌘D"), ("Transcript", "esc"), ("Actions", "⌘K")])
            return
        }
        if let chat = selectedChat {
            footer.attributedStringValue = fitted(chatFooter(chat))
            return
        }
        let acts = actions(for: s)
        var items: [(String, String)] = []
        if let first = acts.first { items.append((first.title.replacingOccurrences(of: " in Terminal", with: ""), "↵")) }
        if s.needsTrust { items.append(("Trust Folder", "⌘T")) }
        if s.herdrPane != nil && !s.needsTrust && s.status != .finished { items.append(("Prompt", "⌘P")) }
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
        let (symbol, tint): (String, NSColor) = switch s.provider {
        case .claude: ("asterisk", Theme.chart2)
        case .opencode: ("chevron.left.forwardslash.chevron.right", Theme.chart3)
        case .codex: ("hexagon", Theme.chart4)
        case .cursor: ("cursorarrow.rays", Theme.chart5)
        }
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
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.88).cgColor
        glass.contentView = content
        root = glass
        updateCorners()

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
        groupControl.segmentStyle = .roundRect
        groupControl.controlSize = .small
        groupControl.font = Theme.sans(11.5, 500)
        groupControl.trackingMode = .selectOne
        groupControl.segmentCount = AgentGrouping.GroupBy.allCases.count
        for (i, g) in AgentGrouping.GroupBy.allCases.enumerated() { groupControl.setLabel(g.label, forSegment: i) }
        groupControl.selectedSegment = AgentGrouping.GroupBy.allCases.firstIndex(of: groupBy) ?? 0
        groupControl.toolTip = "Group by (⌘⇧G) · ⌘1…⌘9 environment · ⌥⌘1…⌥⌘4 status · ⌘0 / ⌥⌘0 all"
        groupControl.target = self
        groupControl.action = #selector(groupClicked)
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

        promptBarHeight = promptBar.heightAnchor.constraint(equalToConstant: 0)
        let detailRule = NSView()
        detailRule.wantsLayer = true
        detailRule.layer?.backgroundColor = Theme.border.cgColor
        promptBar.isBordered = false
        promptBar.drawsBackground = true
        promptBar.backgroundColor = Theme.card
        promptBar.focusRingType = .none
        promptBar.font = Theme.sans(13.5)
        promptBar.textColor = Theme.foreground
        promptBar.wantsLayer = true
        promptBar.layer?.cornerRadius = 8
        promptBar.layer?.borderWidth = 1
        promptBar.layer?.borderColor = Palette.agents.withAlphaComponent(0.6).cgColor
        promptBar.cell?.isScrollable = true
        promptBar.cell?.wraps = false
        promptBar.delegate = self
        promptBar.isHidden = true
        chatView.isHidden = true
        for v in [titleLabel, chip, metaLabel, detailRule, transcriptScroll, promptBar, chatView] as [NSView] {
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
            transcriptScroll.bottomAnchor.constraint(equalTo: promptBar.topAnchor, constant: -4),
            promptBar.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 22),
            promptBar.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -22),
            promptBar.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -8),
            promptBarHeight,
            chatView.topAnchor.constraint(equalTo: detailRule.bottomAnchor, constant: 4),
            chatView.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 18),
            chatView.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -14),
            chatView.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor),
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

        for v in [header, topRule, groupControl, listScroll, emptyLabel, midRule, detailBox, form, bottomRule, countLabel, footer, actionPanel] as [NSView] {
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

            groupControl.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 8),
            groupControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            groupControl.trailingAnchor.constraint(lessThanOrEqualTo: listScroll.trailingAnchor, constant: -12),
            listScroll.topAnchor.constraint(equalTo: groupControl.bottomAnchor, constant: 4),
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
        allSessions.map { s in
            [s.host ?? "local", s.provider.rawValue, s.kind.rawValue, s.remoteID ?? "-", s.tmux ?? s.herdrPane.map { "herdr:\($0)" } ?? "-",
             s.isViewOnly ? "view-only" : (s.isAttachable ? "attachable" : "-"), s.status.label, s.detail ?? "-", s.webURL?.absoluteString ?? "-", s.title]
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// Answers the trust question in a listed hop session, as Trust Folder & Start does.
    /// "name" or "name@host".
    func debugConfirmTrust(_ spec: String) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let tmux = parts[0], host = parts.count > 1 ? parts[1] : nil
        guard let s = store.sessions.first(where: { ($0.tmux == tmux || $0.herdrName == tmux) && $0.needsTrust && $0.host == host }) else {
            HUD.shared.fail("No trust question in \(tmux)")
            return
        }
        confirmTrust(s)
    }

    /// "agent-name|text" or "agent-name@host|text": sends a quick prompt to a herdr agent, as Send Prompt does.
    func debugPrompt(_ spec: String) {
        let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
        let target = parts.first?.split(separator: "@", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2, let name = target.first,
              let s = store.sessions.first(where: { $0.herdrName == name && $0.host == (target.count > 1 ? target[1] : nil) }) else {
            HUD.shared.fail("No herdr agent \(spec)")
            return
        }
        promptTarget = s
        promptBar.stringValue = parts[1]
        promptBar.isHidden = false
        sendPrompt()
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
