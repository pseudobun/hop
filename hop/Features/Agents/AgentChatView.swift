import AppKit

// MARK: - Pure parts

/// Just enough Markdown for agent replies: fenced code blocks, `code` spans, **bold** and
/// `#` headings; everything else is text as written.
nonisolated enum ChatMarkdown {
    enum Segment: Equatable {
        case text(String)
        case code(String)
        case bold(String)
        case heading(String)
        /// A fenced block, without its fences.
        case block(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [Substring] = []
        var block: [Substring]?
        func flushProse() {
            guard !prose.isEmpty else { return }
            for (i, line) in prose.enumerated() {
                let nl = i < prose.count - 1 ? "\n" : ""
                let trimmed = line.drop { $0 == " " }
                if trimmed.hasPrefix("#") {
                    let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty, trimmed.dropFirst(trimmed.prefix { $0 == "#" }.count).first == " " {
                        out.append(.heading(title))
                        if !nl.isEmpty { append(&out, .text(nl)) }
                        continue
                    }
                }
                for s in inline(String(line) + nl) { append(&out, s) }
            }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let b = block {
                    out.append(.block(b.joined(separator: "\n")))
                    block = nil
                } else {
                    flushProse()
                    block = []
                }
                continue
            }
            if block != nil { block!.append(line) } else { prose.append(line) }
        }
        flushProse()
        // An unclosed fence (still streaming) is a block so far.
        if let b = block { out.append(.block(b.joined(separator: "\n"))) }
        return out
    }

    /// `code` and **bold** inside one line.
    static func inline(_ line: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(line)
        while !rest.isEmpty {
            let tick = rest.firstIndex(of: "`")
            let star = rest.range(of: "**")
            if let tick, star.map({ tick < $0.lowerBound }) ?? true,
               let close = rest[rest.index(after: tick)...].firstIndex(of: "`") {
                if tick > rest.startIndex { append(&out, .text(String(rest[..<tick]))) }
                let code = rest[rest.index(after: tick)..<close]
                if code.isEmpty { append(&out, .text("``")) } else { out.append(.code(String(code))) }
                rest = rest[rest.index(after: close)...]
            } else if let star, let close = rest[star.upperBound...].range(of: "**"), close.lowerBound > star.upperBound {
                if star.lowerBound > rest.startIndex { append(&out, .text(String(rest[..<star.lowerBound]))) }
                out.append(.bold(String(rest[star.upperBound..<close.lowerBound])))
                rest = rest[close.upperBound...]
            } else {
                append(&out, .text(String(rest)))
                break
            }
        }
        return out
    }

    /// Adjacent text joins up.
    private static func append(_ out: inout [Segment], _ s: Segment) {
        if case .text(let t) = s, case .text(let prev)? = out.last {
            out[out.count - 1] = .text(prev + t)
        } else {
            out.append(s)
        }
    }
}

/// What a key does in the chat composer.
nonisolated enum ChatComposerKey: Equatable {
    case send
    /// ⇧↵ / ⌥↵: the text view inserts the newline.
    case newline
    /// Tab, Esc, ⌘L: back to the list.
    case leave
    /// ⌃C, ⌘.: stop the turn.
    case interrupt

    /// `characters`: `charactersIgnoringModifiers`.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> ChatComposerKey? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let c = characters?.lowercased()
        switch (keyCode, mods) {
        case (36, []), (76, []): return .send
        case (36, .shift), (76, .shift), (36, .option), (76, .option): return .newline
        case (48, []), (53, []): return .leave
        default: break
        }
        if mods == .command, c == "l" { return .leave }
        if mods == .control, c == "c" { return .interrupt }
        if mods == .command, c == "." { return .interrupt }
        return nil
    }
}

// MARK: - Rendering

/// Chat rows as styled text, one attributed string per item so a change re-renders only its row.
enum ChatRender {
    private static func paragraph(spacing: CGFloat = 8, indent: CGFloat = 0, lineSpacing: CGFloat = 2) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.lineSpacing = lineSpacing
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        return p
    }

    static func item(_ item: ChatItem, speaker: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch item.kind {
        case .user:
            out.append(Theme.labelString("You", color: Palette.agents))
            out.append(NSAttributedString(string: "\n" + item.text + "\n", attributes: [
                .font: Theme.sans(13.5, 500), .foregroundColor: Theme.foreground, .paragraphStyle: paragraph(spacing: 10),
            ]))
        case .assistant:
            out.append(Theme.labelString(item.streaming ? "\(speaker) …" : speaker))
            out.append(NSAttributedString(string: "\n"))
            out.append(markdown(item.text))
            out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.sans(13.5), .paragraphStyle: paragraph(spacing: 10)]))
        case .tool:
            out.append(toolLine(glyph: glyph(item.status), name: item.name ?? "Tool", summary: item.text, status: item.status))
            if let output = item.output, !output.isEmpty { out.append(excerpt(output, failed: item.status == .failed)) }
        case .fileChange:
            out.append(toolLine(glyph: glyph(item.status), name: item.name ?? "Edit", summary: item.path ?? item.text, status: item.status))
            if let diff = item.diff, !diff.isEmpty { out.append(self.diff(diff)) }
        case .approval:
            out.append(approval(item))
        case .notice:
            out.append(NSAttributedString(string: "— \(item.text) —\n", attributes: [
                .font: Theme.mono(11.5), .foregroundColor: Theme.mutedForeground, .paragraphStyle: paragraph(spacing: 10),
            ]))
        case .error:
            out.append(NSAttributedString(string: item.text + "\n", attributes: [
                .font: Theme.mono(12), .foregroundColor: Theme.destructive, .paragraphStyle: paragraph(spacing: 10),
            ]))
        }
        return out
    }

    static func glyph(_ s: ChatItem.Status) -> (String, NSColor) {
        switch s {
        case .running: ("◌", Theme.info)
        case .done: ("✓", Theme.good)
        case .failed: ("✗", Theme.destructive)
        case .declined: ("⊘", Theme.mutedForeground)
        }
    }

    private static func toolLine(glyph: (String, NSColor), name: String, summary: String, status: ChatItem.Status) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let p = paragraph(spacing: 3)
        out.append(NSAttributedString(string: glyph.0 + " ", attributes: [.font: Theme.mono(12, 500), .foregroundColor: glyph.1, .paragraphStyle: p]))
        out.append(NSAttributedString(string: name, attributes: [
            .font: Theme.mono(12, 500), .foregroundColor: status == .declined ? Theme.mutedForeground : Theme.info, .paragraphStyle: p,
        ]))
        let line = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clipped = line.count > 200 ? String(line.prefix(200)) + "…" : line
        out.append(NSAttributedString(string: (clipped.isEmpty ? "" : "  " + clipped) + "\n", attributes: [
            .font: Theme.mono(12), .foregroundColor: Theme.mutedForeground, .paragraphStyle: p,
        ]))
        return out
    }

    /// The last few lines of a tool's output, dimmed and indented.
    private static func excerpt(_ text: String, failed: Bool, lines: Int = 4) -> NSAttributedString {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = all.suffix(lines).map { $0.count > 240 ? $0.prefix(240) + "…" : $0 }.joined(separator: "\n")
        if all.count > lines { shown = "… \(all.count - lines) more lines\n" + shown }
        return NSAttributedString(string: shown + "\n", attributes: [
            .font: Theme.mono(11.5), .foregroundColor: failed ? Theme.destructive.withAlphaComponent(0.8) : Theme.mutedForeground.withAlphaComponent(0.7),
            .paragraphStyle: paragraph(spacing: 8, indent: 16, lineSpacing: 0),
        ])
    }

    /// A diff coloured like Show Changes: additions good, removals destructive.
    private static func diff(_ text: String, maxLines: Int = 40) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let p = paragraph(spacing: 0, indent: 16, lineSpacing: 0)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.prefix(maxLines) {
            let color: NSColor = switch GitChanges.style(line) {
            case .added: Theme.good
            case .removed: Theme.destructive
            case .hunk: Theme.mutedForeground
            case .file: Theme.info
            case .context: Theme.foreground.withAlphaComponent(0.8)
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: Theme.mono(11.5), .foregroundColor: color, .paragraphStyle: p]))
        }
        if lines.count > maxLines {
            out.append(NSAttributedString(string: "… \(lines.count - maxLines) more lines\n", attributes: [
                .font: Theme.mono(11.5), .foregroundColor: Theme.mutedForeground, .paragraphStyle: p,
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono(6)]))
        return out
    }

    private static func approval(_ item: ChatItem) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let a = item.approval else { return out }
        let (state, color): (String, NSColor) = switch a.state {
        case .pending: ("waits for you · ⌘Y allow\(a.options.contains(.allowAlways) ? " · ⌘⇧Y always" : "") · ⌘⇧N deny", Theme.warn)
        case .allowed: ("allowed", Theme.good)
        case .denied: ("denied", Theme.destructive)
        case .cancelled: ("withdrawn", Theme.mutedForeground)
        }
        let p = paragraph(spacing: 2)
        out.append(NSAttributedString(string: "⚑ \(a.title)  ", attributes: [.font: Theme.mono(12, 600), .foregroundColor: color, .paragraphStyle: p]))
        out.append(NSAttributedString(string: state + "\n", attributes: [.font: Theme.mono(11.5), .foregroundColor: color.withAlphaComponent(0.85), .paragraphStyle: p]))
        if !a.detail.isEmpty {
            let detail = a.detail.count > 600 ? String(a.detail.prefix(600)) + "…" : a.detail
            out.append(NSAttributedString(string: detail + "\n", attributes: [
                .font: Theme.mono(12), .foregroundColor: Theme.foreground.withAlphaComponent(0.85), .paragraphStyle: paragraph(spacing: 2, indent: 16, lineSpacing: 0),
            ]))
        }
        if let reason = a.reason, !reason.isEmpty {
            out.append(NSAttributedString(string: reason + "\n", attributes: [
                .font: Theme.sans(12.5), .foregroundColor: Theme.mutedForeground, .paragraphStyle: paragraph(spacing: 2, indent: 16),
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono(6)]))
        return out
    }

    static func markdown(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = paragraph(spacing: 4)
        let base: [NSAttributedString.Key: Any] = [.font: Theme.sans(13.5), .foregroundColor: Theme.foreground.withAlphaComponent(0.92), .paragraphStyle: body]
        for seg in ChatMarkdown.segments(text) {
            switch seg {
            case .text(let t): out.append(NSAttributedString(string: t, attributes: base))
            case .bold(let t):
                var a = base
                a[.font] = Theme.sans(13.5, 600)
                out.append(NSAttributedString(string: t, attributes: a))
            case .code(let t):
                var a = base
                a[.font] = Theme.mono(12.5)
                a[.foregroundColor] = Theme.info
                a[.backgroundColor] = Theme.muted
                out.append(NSAttributedString(string: t, attributes: a))
            case .heading(let t):
                out.append(NSAttributedString(string: t, attributes: [.font: Theme.sans(15, 600), .foregroundColor: Theme.foreground, .paragraphStyle: body]))
            case .block(let t):
                if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: base)) }
                out.append(NSAttributedString(string: t + "\n", attributes: [
                    .font: Theme.mono(12), .foregroundColor: Theme.foreground.withAlphaComponent(0.9), .backgroundColor: Theme.card,
                    .paragraphStyle: paragraph(spacing: 0, indent: 10, lineSpacing: 1),
                ]))
            }
        }
        return out
    }

    /// The earlier conversation, as the observe-only view draws it, dimmed.
    static func history(_ entries: [TranscriptEntry], provider: AgentProvider) -> NSAttributedString {
        guard !entries.isEmpty else { return NSAttributedString() }
        let out = NSMutableAttributedString(attributedString: AgentsController.render(entries, provider: provider, empty: ""))
        out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let c = value as? NSColor else { return }
            out.addAttribute(.foregroundColor, value: c.withAlphaComponent(c.alphaComponent * 0.55), range: range)
        }
        out.append(NSAttributedString(string: "— continued in hop —\n\n", attributes: [
            .font: Theme.mono(11.5), .foregroundColor: Palette.agents,
        ]))
        return out
    }
}

// MARK: - Views

/// The multi-line message field: ↵ is handled by the panel (sends), ⇧↵ a newline here.
final class ChatComposerTextView: NSTextView {
    var placeholder = ""
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: [
            .font: Theme.sans(13.5), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.6),
        ]).draw(at: origin)
    }
}

/// The selected chat: conversation above, the first pending approval as a card, the composer below.
final class AgentChatView: NSView {
    var onSend: ((String) -> Void)?
    var onDecision: ((String, ChatDecision) -> Void)?
    /// The composer gained or lost focus (the footer changes).
    var onFocusChange: (() -> Void)?

    let composer = ChatComposerTextView()
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let composerScroll = NSScrollView()
    private let card = NSView()
    private let cardTitle = NSTextField(labelWithString: "")
    private let cardDetail = NSTextField(wrappingLabelWithString: "")
    private let cardButtons = NSStackView()
    private var cardHeight: NSLayoutConstraint!

    /// What the text storage shows: the chat, its history length, then each item and its length.
    private var shownID: String?
    private var historyLength = 0
    private var historyCount = -1
    private var shownItems: [ChatItem] = []
    private var lengths: [Int] = []
    private var pendingID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isComposerFocused: Bool { window?.firstResponder === composer }

    func focusComposer() { window?.makeFirstResponder(composer) }

    /// The composer's text, cleared.
    func takeMessage() -> String {
        let s = composer.string
        composer.string = ""
        composer.needsDisplay = true
        return s
    }

    /// Shows `chat`, re-rendering only the rows that changed since the last call.
    func show(_ chat: ChatSession) {
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= text.frame.height - 24
        let storage = text.textStorage!
        let items = chat.backend.items
        let speaker = chat.provider.speaker
        storage.beginEditing()
        if shownID != chat.id || historyCount != chat.history.count {
            shownID = chat.id
            historyCount = chat.history.count
            let history = ChatRender.history(ChatRows.history(chat.history), provider: chat.provider)
            storage.setAttributedString(history)
            historyLength = history.length
            shownItems = []
            lengths = []
        }
        var first = 0
        while first < min(items.count, shownItems.count), items[first] == shownItems[first] { first += 1 }
        if first < shownItems.count || first < items.count {
            let start = historyLength + lengths.prefix(first).reduce(0, +)
            let tail = NSMutableAttributedString()
            lengths.removeSubrange(first...)
            for item in items[first...] {
                let r = ChatRender.item(item, speaker: speaker)
                lengths.append(r.length)
                tail.append(r)
            }
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            shownItems = items
        }
        if storage.length == 0 {
            storage.setAttributedString(NSAttributedString(string: "Starting \(chat.provider.label)…", attributes: [
                .font: Theme.meta, .foregroundColor: Theme.mutedForeground,
            ]))
            historyLength = storage.length
            historyCount = -1
        }
        storage.endEditing()
        if atBottom { text.scrollToEndOfDocument(nil) }
        updateCard(chat.backend.pendingApprovals.first)
        updateComposer(chat)
    }

    /// Forget what is shown (the next `show` draws everything).
    func reset() {
        shownID = nil
        historyCount = -1
        shownItems = []
        lengths = []
        text.textStorage?.setAttributedString(NSAttributedString())
    }

    private func updateComposer(_ chat: ChatSession) {
        let status = chat.backend.status
        let ended = status == .ended || status == .failed
        composer.isEditable = !ended
        composer.placeholder = switch status {
        case .starting: "Starting \(chat.provider.label)… ↵ queues a message"
        case .running: "Working… ↵ queues the next message · ⌃C interrupts"
        case .waitingForApproval: "Waiting on an approval: ⌘Y allows, ⌘⇧N denies"
        case .idle: "Message \(chat.provider.speaker) · ↵ sends · ⇧↵ new line"
        case .ended, .failed: "Chat ended · ⌘⇧↵ continues it"
        }
        composer.needsDisplay = true
        if ended, isComposerFocused { window?.makeFirstResponder(nil) }
    }

    private func updateCard(_ a: ChatApproval?) {
        guard let a else {
            pendingID = nil
            card.isHidden = true
            cardHeight.isActive = true
            return
        }
        card.isHidden = false
        cardHeight.isActive = false
        guard pendingID != a.id else { return }
        pendingID = a.id
        let title = NSMutableAttributedString(attributedString: Theme.labelString("Approval", color: Theme.warn))
        title.append(NSAttributedString(string: "  " + a.title, attributes: [.font: Theme.sans(14, 600), .foregroundColor: Theme.foreground]))
        cardTitle.attributedStringValue = title
        var detail = a.detail.count > 400 ? String(a.detail.prefix(400)) + "…" : a.detail
        if let reason = a.reason, !reason.isEmpty { detail += (detail.isEmpty ? "" : "\n") + reason }
        cardDetail.attributedStringValue = NSAttributedString(string: detail, attributes: [
            .font: Theme.mono(12), .foregroundColor: Theme.foreground.withAlphaComponent(0.85),
        ])
        for v in cardButtons.arrangedSubviews { v.removeFromSuperview() }
        for d in a.options {
            let key = switch d {
            case .allow: "⌘Y"
            case .allowAlways: "⌘⇧Y"
            case .deny: "⌘⇧N"
            }
            let b = NSButton(title: "", target: self, action: #selector(decisionClicked(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.identifier = NSUserInterfaceItemIdentifier(d.rawValue)
            b.attributedTitle = Keycap.label(d.label, keys: key)
            if d == .allow { b.bezelColor = Theme.primary }
            cardButtons.addArrangedSubview(b)
        }
    }

    @objc private func decisionClicked(_ sender: NSButton) {
        guard let id = pendingID, let raw = sender.identifier?.rawValue, let d = ChatDecision(rawValue: raw) else { return }
        onDecision?(id, d)
    }

    private func build() {
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 2, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.selectedTextAttributes = [.backgroundColor: Palette.agents.withAlphaComponent(0.28)]
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.card.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.warn.withAlphaComponent(0.6).cgColor
        card.isHidden = true
        cardDetail.maximumNumberOfLines = 5
        cardDetail.lineBreakMode = .byTruncatingTail
        cardDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cardButtons.spacing = 8
        for v in [cardTitle, cardDetail, cardButtons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }

        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.font = Theme.sans(13.5)
        composer.textColor = Theme.foreground
        composer.insertionPointColor = Theme.foreground
        composer.typingAttributes = [.font: Theme.sans(13.5), .foregroundColor: Theme.foreground]
        composer.textContainerInset = NSSize(width: 6, height: 7)
        composer.isVerticallyResizable = true
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.onFocus = { [weak self] in self?.onFocusChange?() }
        composerScroll.documentView = composer
        composerScroll.drawsBackground = true
        composerScroll.backgroundColor = Theme.card
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 8
        composerScroll.layer?.borderWidth = 1
        composerScroll.layer?.borderColor = Palette.agents.withAlphaComponent(0.5).cgColor

        for v in [scroll, card, composerScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        cardHeight = card.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -6),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            card.bottomAnchor.constraint(equalTo: composerScroll.topAnchor, constant: -8),
            cardTitle.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            cardTitle.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            cardDetail.topAnchor.constraint(equalTo: cardTitle.bottomAnchor, constant: 6),
            cardDetail.leadingAnchor.constraint(equalTo: cardTitle.leadingAnchor),
            cardDetail.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            cardButtons.topAnchor.constraint(equalTo: cardDetail.bottomAnchor, constant: 8),
            cardButtons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            { let c = cardButtons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10); c.priority = .init(999); return c }(),
            composerScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            composerScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            composerScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            composerScroll.heightAnchor.constraint(equalToConstant: 64),
            cardHeight,
        ])
    }
}
