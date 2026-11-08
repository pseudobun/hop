import AppKit

/// "New session" in the Agents panel: provider, where, folder (recent projects and path
/// completion, pinned ones first), permission mode, an optional new git worktree and an
/// optional first prompt, and where it runs (a terminal, or a hop chat for Claude Code and
/// Codex). Keyboard first: Tab completes, ↵ moves on and starts, ⌘P / ⌘T / ⌘M / ⌘E switch
/// provider, target, mode and Run in, ⌘G toggles the worktree, ⌘⇧P pins the highlighted
/// folder; every control also takes clicks.
final class AgentSpawnView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onStart: ((AgentCommands.Spawn, HopConfig.Agents.Host?) -> Void)?
    /// Start it as a hop chat instead (Run in: Chat).
    var onStartChat: ((AgentCommands.Spawn, HopConfig.Agents.Host?) -> Void)?
    var onCancel: (() -> Void)?
    var isBusy = false {
        didSet { startButton.isEnabled = !isBusy }
    }

    private var providers: [AgentProvider] = []
    private var hosts: [HopConfig.Agents.Host] = []
    private var projects: (HopConfig.Agents.Host?) -> [String] = { _ in [] }
    private var defaultCwd: (HopConfig.Agents.Host?) -> String = { _ in "~" }
    private var multiplexer: (HopConfig.Agents.Host?) -> HopConfig.Agents.Multiplexer = { _ in .tmux }
    private var isPinned: (String, HopConfig.Agents.Host?) -> Bool = { _, _ in false }
    private var togglePin: ((String, HopConfig.Agents.Host?) -> Void)?
    private var known: [String] = []
    private var suggestions: [String] = []

    private let heading = NSTextField(labelWithString: "New session")
    private let providerControl = NSSegmentedControl()
    private let hostControl = NSSegmentedControl()
    private let folderField = NSTextField()
    private let suggestionTable = NSTableView()
    private let suggestionScroll = NSScrollView()
    private let promptField = NSTextField()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithAttributedString: Theme.labelString("Where ⌘T"))
    private let modeControl = NSSegmentedControl()
    private let worktreeCheck = NSButton(checkboxWithTitle: "New git worktree ⌘G", target: nil, action: nil)
    private let runInLabel = NSTextField(labelWithAttributedString: Theme.labelString("Run in ⌘E"))
    private let runInControl = NSSegmentedControl()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var host: HopConfig.Agents.Host? {
        let i = hostControl.selectedSegment
        return i > 0 && i <= hosts.count ? hosts[i - 1] : nil
    }

    private var provider: AgentProvider {
        let i = providerControl.selectedSegment
        return i >= 0 && i < providers.count ? providers[i] : .claude
    }

    private var mode: AgentPermissionMode {
        let i = modeControl.selectedSegment
        return i >= 0 && i < AgentPermissionMode.allCases.count ? AgentPermissionMode.allCases[i] : .supervised
    }

    /// Claude Code and Codex can run as a hop chat.
    private var chatAvailable: Bool { ChatRows.chatProvider(provider) != nil }

    /// Run in: Chat is picked and the provider has one.
    var runsInChat: Bool { chatAvailable && runInControl.selectedSegment == 1 }

    /// The worktree box is offered and ticked.
    private var wantsWorktree: Bool { !worktreeCheck.isHidden && worktreeCheck.state == .on }

    func configure(providers: [AgentProvider], preferred: AgentProvider, hosts: [HopConfig.Agents.Host], host: String?,
                   defaultCwd: @escaping (HopConfig.Agents.Host?) -> String, cwd: String?,
                   projects: @escaping (HopConfig.Agents.Host?) -> [String],
                   multiplexer: @escaping (HopConfig.Agents.Host?) -> HopConfig.Agents.Multiplexer = { _ in .tmux },
                   mode: AgentPermissionMode = .supervised,
                   runIn: HopConfig.Agents.RunIn = .terminal,
                   isPinned: @escaping (String, HopConfig.Agents.Host?) -> Bool = { _, _ in false },
                   togglePin: ((String, HopConfig.Agents.Host?) -> Void)? = nil) {
        self.multiplexer = multiplexer
        self.isPinned = isPinned
        self.togglePin = togglePin
        modeControl.selectedSegment = AgentPermissionMode.allCases.firstIndex(of: mode) ?? 0
        runInControl.selectedSegment = runIn == .chat ? 1 : 0
        worktreeCheck.state = .off
        self.providers = providers
        self.hosts = hosts
        self.projects = projects
        self.defaultCwd = defaultCwd
        providerControl.segmentCount = providers.count
        for (i, p) in providers.enumerated() {
            providerControl.setLabel(p.label, forSegment: i)
            providerControl.setWidth(0, forSegment: i)
        }
        providerControl.selectedSegment = providers.firstIndex(of: preferred) ?? 0
        hostControl.segmentCount = hosts.count + 1
        hostControl.setLabel("This Mac", forSegment: 0)
        for (i, h) in hosts.enumerated() { hostControl.setLabel(h.label, forSegment: i + 1) }
        hostControl.selectedSegment = host.flatMap { label in hosts.firstIndex { $0.label == label }.map { $0 + 1 } } ?? 0
        hostControl.isHidden = hosts.isEmpty
        hostLabel.isHidden = hosts.isEmpty
        promptField.stringValue = ""
        isBusy = false
        targetChanged(keepFolder: cwd)
    }

    func focus(in window: NSWindow) {
        window.makeFirstResponder(folderField)
        folderField.currentEditor()?.selectAll(nil)
    }

    private func targetChanged(keepFolder: String? = nil) {
        known = projects(host)
        let cwd = keepFolder.map { host == nil ? ($0 as NSString).abbreviatingWithTildeInPath : $0 } ?? defaultCwd(host)
        folderField.stringValue = cwd
        updateSuggestions(all: true)
        updateNote()
    }

    /// Whether the folder is in a git repository: a `.git` in it or a parent (this Mac); a
    /// remote folder is not looked at, the script there says when it is not one.
    static func isGitRepository(_ path: String) -> Bool {
        var dir = (path.expandingTilde as NSString).standardizingPath
        let fm = FileManager.default
        while !dir.isEmpty {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return true }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return false
    }

    /// What starting does, and whether Claude Code will first ask to trust the folder (this Mac only).
    private func updateNote() {
        runInControl.isEnabled = chatAvailable
        let folder = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        worktreeCheck.isHidden = host == nil && !(folder.hasPrefix("/") || folder.hasPrefix("~") ? Self.isGitRepository(folder) : false)
        let where_ = host.map { "on \($0.label) over ssh" } ?? "on this Mac"
        var trust = ""
        if provider == .claude, host == nil, ClaudeTrust.isTrusted(localFolder: folderField.stringValue.trimmingCharacters(in: .whitespaces)) == false {
            trust = "Claude Code has not trusted this folder yet and asks first; Trust Folder & Start (⌘T) in the list answers it. "
        }
        let in_ = multiplexer(host) == .herdr
            ? "in a herdr workspace and agent named hop-\(provider.tag)-… (tmux when herdr is not there)"
            : "in a tmux session named hop-\(provider.tag)-…"
        let worktree = wantsWorktree ? "in a new git worktree on branch hop/…, " : ""
        if runsInChat {
            note.stringValue = "Starts \(provider.label) \(worktree)\(where_) as a chat in this panel: replies stream here and "
                + "approvals wait for ⌘Y / ⌘⇧N. It ends when hop quits; Continue in Chat (⌘⇧↵) picks it up again."
            return
        }
        let flags = mode.arguments(for: provider)
        let modeNote = mode == .supervised ? "" : flags.isEmpty ? " \(provider.label) has no \(mode.label) mode: it starts as usual." : ""
        note.stringValue = trust + "Starts \(provider.label) \(worktree)\(where_) \(in_), so it keeps running "
            + "after hop quits. ⌘↵ in the list attaches a terminal to it." + modeNote
            + (provider == .claude ? " Remote Control (agents.claude.remoteControl) lets the Claude app continue it." : "")
    }

    // MARK: - Suggestions

    /// Known projects matching the folder text, or for a typed path (local only) its subfolders.
    private func updateSuggestions(all: Bool = false) {
        let text = folderField.stringValue
        let fm = FileManager.default
        if host == nil, !all, text.hasPrefix("/") || text.hasPrefix("~") {
            let expanded = text.expandingTilde
            let parent = text.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
            let prefix = text.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
            let names = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
            let base = text.hasSuffix("/") ? text : String(text.prefix(text.count - (text as NSString).lastPathComponent.count))
            suggestions = names.sorted().filter { n in
                var dir: ObjCBool = false
                return !n.hasPrefix(".") && (prefix.isEmpty || n.lowercased().hasPrefix(prefix))
                    && fm.fileExists(atPath: (parent as NSString).appendingPathComponent(n), isDirectory: &dir) && dir.boolValue
            }.prefix(50).map { base + $0 }
            let fromKnown = known.filter { $0.lowercased().hasPrefix(text.lowercased()) && !suggestions.contains($0) }
            suggestions = Array((fromKnown + suggestions).prefix(60))
        } else {
            let q = all ? "" : text.lowercased()
            suggestions = q.isEmpty ? known : known.filter { p in
                q.split(separator: " ").allSatisfy { p.lowercased().contains($0) }
            }
        }
        suggestionTable.reloadData()
        if !suggestions.isEmpty {
            suggestionTable.selectRowIndexes([0], byExtendingSelection: false)
            suggestionTable.scrollRowToVisible(0)
        }
    }

    private var highlighted: String? {
        let r = suggestionTable.selectedRow
        return r >= 0 && r < suggestions.count ? suggestions[r] : nil
    }

    private func accept(_ path: String, trailingSlash: Bool) {
        folderField.stringValue = trailingSlash && !path.hasSuffix("/") ? path + "/" : path
        folderField.currentEditor()?.moveToEndOfDocument(nil)
        updateSuggestions()
        updateNote()
    }

    private func moveSuggestion(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        let next = max(0, min(suggestions.count - 1, suggestionTable.selectedRow + step))
        suggestionTable.selectRowIndexes([next], byExtendingSelection: false)
        suggestionTable.scrollRowToVisible(next)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === folderField {
            updateSuggestions()
            updateNote()
        }
    }

    // MARK: - Keys

    private var editingFolder: Bool {
        (window?.firstResponder as? NSTextView)?.delegate === folderField
    }

    private var editingPrompt: Bool {
        (window?.firstResponder as? NSTextView)?.delegate === promptField
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(KeyCombo.relevant)
        if event.keyCode == 53 { onCancel?(); return true }
        if KeyCombo.ret(.command).matches(event) { submit(); return true }
        if KeyCombo.cmd("p").matches(event) { cycle(providerControl); return true }
        if KeyCombo.cmd("t").matches(event), !hostControl.isHidden { cycle(hostControl); return true }
        if KeyCombo.cmd("m").matches(event) { cycle(modeControl); return true }
        if KeyCombo.cmd("e").matches(event) {
            if chatAvailable { cycle(runInControl) } else { HUD.shared.show("\(provider.label) runs in a terminal only", symbol: "terminal") }
            return true
        }
        if KeyCombo.cmd("g").matches(event) {
            if !worktreeCheck.isHidden { worktreeCheck.state = worktreeCheck.state == .on ? .off : .on }
            updateNote()
            return true
        }
        if KeyCombo.cmd("p", .shift).matches(event) { pinHighlighted(); return true }
        if editingFolder {
            switch (event.keyCode, mods) {
            case (125, []): moveSuggestion(1); return true
            case (126, []): moveSuggestion(-1); return true
            case (48, []): // Tab: complete; with nothing to complete, on to the prompt
                if let h = highlighted, h != folderField.stringValue && h + "/" != folderField.stringValue {
                    accept(h, trailingSlash: host == nil)
                } else {
                    window?.makeFirstResponder(promptField)
                }
                return true
            case (36, []), (76, []):
                if let h = highlighted, !folderField.stringValue.hasSuffix("/"), h.lowercased().contains(folderField.stringValue.lowercased()),
                   h != folderField.stringValue { accept(h, trailingSlash: false) }
                window?.makeFirstResponder(promptField)
                return true
            default: return false
            }
        }
        if editingPrompt, KeyCombo.ret().matches(event) { submit(); return true }
        return false
    }

    private func cycle(_ control: NSSegmentedControl) {
        guard control.segmentCount > 0 else { return }
        control.selectedSegment = (control.selectedSegment + 1) % control.segmentCount
        if control === modeControl || control === runInControl { updateNote(); return }
        if control === hostControl { targetChanged() } else { targetChanged(keepFolder: folderField.stringValue) }
    }

    /// Pins the highlighted suggestion (or the typed folder), or unpins it; pinned ones list first.
    private func pinHighlighted() {
        guard let togglePin else { return }
        var path = highlighted ?? folderField.stringValue.trimmingCharacters(in: .whitespaces)
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return }
        let was = isPinned(path, host)
        togglePin(path, host)
        HUD.shared.show(was ? "Unpinned \(path)" : "Pinned \(path)", symbol: was ? "pin.slash" : "pin.fill")
        known = projects(host)
        updateSuggestions()
        if let i = suggestions.firstIndex(of: path) {
            suggestionTable.selectRowIndexes([i], byExtendingSelection: false)
            suggestionTable.scrollRowToVisible(i)
        }
    }

    @objc private func modeClicked() { updateNote() }
    @objc private func runInClicked() { updateNote() }
    @objc private func worktreeClicked() { updateNote() }

    @objc private func providerClicked() { targetChanged(keepFolder: folderField.stringValue) }
    @objc private func hostClicked() { targetChanged() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func startClicked() { submit() }

    @objc private func suggestionClicked() {
        let r = suggestionTable.clickedRow
        guard r >= 0, r < suggestions.count else { return }
        accept(suggestions[r], trailingSlash: false)
        window?.makeFirstResponder(folderField)
    }

    private func submit() {
        guard !isBusy else { return }
        var cwd = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        if cwd.isEmpty { cwd = defaultCwd(host) }
        if cwd.count > 1 && cwd.hasSuffix("/") { cwd.removeLast() }
        let name = AgentNames.tmuxName(provider: provider, cwd: cwd, suffix: AgentNames.randomSuffix())
        let spawn = AgentCommands.Spawn(provider: provider, cwd: cwd, prompt: promptField.stringValue, resume: nil, tmuxName: name,
                                        mode: mode, worktree: wantsWorktree ? String(name.dropFirst("hop-xx-".count)) : nil)
        if runsInChat { onStartChat?(spawn, host) } else { onStart?(spawn, host) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.tint = Palette.agents
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AgentFolder")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = Theme.mono(12.5)
            label.textColor = Theme.foreground
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pin = NSTextField(labelWithString: "")
            pin.identifier = NSUserInterfaceItemIdentifier("pin")
            pin.translatesAutoresizingMaskIntoConstraints = false
            pin.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.addSubview(label)
            c.addSubview(pin)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18),
                label.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                pin.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18),
                pin.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = suggestions[row]
        let pin = cell.subviews.first { $0.identifier?.rawValue == "pin" } as? NSTextField
        pin?.attributedStringValue = isPinned(suggestions[row], host) ? Theme.labelString("Pinned") : NSAttributedString()
        return cell
    }

    // MARK: - Layout

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithAttributedString: Theme.labelString(text))
    }

    private func styleField(_ f: NSTextField, placeholder: String, mono: Bool) {
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = Theme.card
        f.focusRingType = .none
        f.font = mono ? Theme.mono(13.5) : Theme.sans(14)
        f.textColor = Theme.foreground
        f.wantsLayer = true
        f.layer?.cornerRadius = 8
        f.layer?.borderWidth = 1
        f.layer?.borderColor = Theme.border.cgColor
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: f.font!, .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.6),
        ])
        f.delegate = self
    }

    private func build() {
        heading.font = Theme.title
        heading.textColor = Theme.foreground

        for c in [providerControl, hostControl] {
            c.segmentStyle = .rounded
            c.controlSize = .regular
            c.font = Theme.sans(13, 500)
            c.trackingMode = .selectOne
            c.target = self
        }
        providerControl.action = #selector(providerClicked)
        hostControl.action = #selector(hostClicked)
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .regular
        modeControl.font = Theme.sans(13, 500)
        modeControl.trackingMode = .selectOne
        modeControl.segmentCount = AgentPermissionMode.allCases.count
        for (i, m) in AgentPermissionMode.allCases.enumerated() {
            modeControl.setLabel(m.label, forSegment: i)
            modeControl.setWidth(0, forSegment: i)
        }
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeClicked)
        runInControl.segmentStyle = .rounded
        runInControl.controlSize = .small
        runInControl.font = Theme.sans(12, 500)
        runInControl.trackingMode = .selectOne
        runInControl.segmentCount = 2
        runInControl.setLabel("Terminal", forSegment: 0)
        runInControl.setLabel("hop Chat", forSegment: 1)
        runInControl.selectedSegment = 0
        runInControl.target = self
        runInControl.action = #selector(runInClicked)
        worktreeCheck.font = Theme.sans(13)
        worktreeCheck.attributedTitle = NSAttributedString(string: "New git worktree ⌘G", attributes: [
            .font: Theme.sans(13), .foregroundColor: Theme.foreground,
        ])
        worktreeCheck.target = self
        worktreeCheck.action = #selector(worktreeClicked)
        worktreeCheck.isHidden = true

        styleField(folderField, placeholder: "~/repos/project", mono: true)
        folderField.cell?.isScrollable = true
        folderField.cell?.wraps = false
        styleField(promptField, placeholder: "Optional first prompt", mono: false)
        promptField.cell?.wraps = true
        promptField.cell?.isScrollable = false
        promptField.usesSingleLineMode = false
        promptField.maximumNumberOfLines = 4

        let column = NSTableColumn(identifier: .init("folder"))
        column.resizingMask = .autoresizingMask
        suggestionTable.addTableColumn(column)
        suggestionTable.headerView = nil
        suggestionTable.style = .plain
        suggestionTable.backgroundColor = .clear
        suggestionTable.intercellSpacing = .zero
        suggestionTable.rowHeight = 26
        suggestionTable.refusesFirstResponder = true
        suggestionTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        suggestionTable.dataSource = self
        suggestionTable.delegate = self
        suggestionTable.target = self
        suggestionTable.action = #selector(suggestionClicked)
        suggestionScroll.documentView = suggestionTable
        suggestionScroll.drawsBackground = false
        suggestionScroll.hasVerticalScroller = true
        suggestionScroll.autohidesScrollers = true
        suggestionScroll.scrollerStyle = .overlay

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = ""
        startButton.bezelColor = Theme.primary
        startButton.target = self
        startButton.action = #selector(startClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        note.font = Theme.sans(12)
        note.textColor = Theme.mutedForeground
        note.maximumNumberOfLines = 4
        note.lineBreakMode = .byWordWrapping
        note.cell?.wraps = true
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let providerLabel = label("Provider ⌘P"), folderLabel = label("Folder · tab completes · ⌘⇧P pins"), promptLabel = label("Prompt · ↵ starts")
        let modeLabel = label("Mode ⌘M")
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.spacing = 8
        let views: [NSView] = [heading, runInLabel, runInControl, providerLabel, providerControl, hostLabel, hostControl, folderLabel, folderField, suggestionScroll,
                               modeLabel, modeControl, worktreeCheck, promptLabel, promptField, note, buttons]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let inset: CGFloat = 22
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            runInControl.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            runInControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            runInLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            runInLabel.trailingAnchor.constraint(equalTo: runInControl.leadingAnchor, constant: -10),
            providerLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            providerLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            providerControl.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerControl.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            hostLabel.topAnchor.constraint(equalTo: providerLabel.topAnchor),
            hostLabel.leadingAnchor.constraint(equalTo: hostControl.leadingAnchor),
            hostControl.topAnchor.constraint(equalTo: providerControl.topAnchor),
            hostControl.leadingAnchor.constraint(equalTo: providerControl.trailingAnchor, constant: 24),
            hostControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            folderLabel.topAnchor.constraint(equalTo: providerControl.bottomAnchor, constant: 16),
            folderLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            folderField.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 6),
            folderField.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            folderField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            folderField.heightAnchor.constraint(equalToConstant: 30),
            suggestionScroll.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 4),
            suggestionScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset - 10),
            suggestionScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset - 10)),
            suggestionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
            modeLabel.topAnchor.constraint(equalTo: suggestionScroll.bottomAnchor, constant: 12),
            modeLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            modeControl.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            worktreeCheck.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            worktreeCheck.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 24),
            worktreeCheck.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            promptLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 14),
            promptLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            promptField.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            promptField.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            promptField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            promptField.heightAnchor.constraint(equalToConstant: 64),
            note.topAnchor.constraint(equalTo: promptField.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            buttons.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        providerLabel.setContentHuggingPriority(.required, for: .vertical)
        suggestionScroll.setContentHuggingPriority(.init(1), for: .vertical)
    }
}
