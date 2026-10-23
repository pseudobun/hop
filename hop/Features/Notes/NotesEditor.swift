import AppKit

extension NSAttributedString.Key {
    /// Link target of a Markdown span (`note:<name>` or a URL); ⌘-click follows it.
    static let hopLink = NSAttributedString.Key("hopLink")
}

/// Plain-text Markdown editor: live styling, ⌘-click on links, click on task boxes,
/// list continuation on ↵.
final class NotesTextView: NSTextView {
    var onOpenLink: ((String) -> Void)?

    static func make() -> NotesTextView {
        let view = NotesTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.insertionPointColor = Theme.foreground
        view.selectedTextAttributes = [.backgroundColor: Palette.notes.withAlphaComponent(0.28)]
        view.textContainerInset = NSSize(width: 26, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.typingAttributes = MarkdownTheme.base
        return view
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, index < storage.length {
            if event.modifierFlags.contains(.command),
               let target = storage.attribute(.hopLink, at: index, effectiveRange: nil) as? String {
                onOpenLink?(target)
                return
            }
            if toggleTaskBox(at: index, in: storage) { return }
        }
        super.mouseDown(with: event)
    }

    /// A click on `[ ]` / `[x]` flips it (undoable).
    private func toggleTaskBox(at index: Int, in storage: NSTextStorage) -> Bool {
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        for s in MarkdownStyler.spans(ns.substring(with: line)) {
            guard case .task(let done) = s.span else { continue }
            let box = NSRange(location: line.location + s.range.location, length: s.range.length)
            guard NSLocationInRange(index, box) || index == box.upperBound - 1 else { return false }
            let inner = NSRange(location: box.location + 1, length: 1)
            let replacement = done ? " " : "x"
            if shouldChangeText(in: inner, replacementString: replacement) {
                storage.replaceCharacters(in: inner, with: replacement)
                didChangeText()
            }
            return true
        }
        return false
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)), continueList() { return }
        super.doCommand(by: selector)
    }

    /// ↵ in a list item starts the next one; ↵ in an empty item ends the list.
    private func continueList() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        guard sel.location == contentsEnd else { return false }
        let text = ns.substring(with: NSRange(location: line.location, length: contentsEnd - line.location))
        switch MarkdownEditing.continueList(text) {
        case .insert(let prefix):
            insertText("\n" + prefix, replacementRange: sel)
        case .endList(let length):
            insertText("", replacementRange: NSRange(location: line.location, length: length))
        case nil:
            return false
        }
        return true
    }

    /// ⌘L: toggle a task on the current line.
    func toggleTaskOnCurrentLine() {
        let ns = string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        let range = NSRange(location: line.location, length: contentsEnd - line.location)
        let old = ns.substring(with: range)
        let new = MarkdownEditing.toggleTask(old)
        insertText(new, replacementRange: range)
        let delta = (new as NSString).length - (old as NSString).length
        setSelectedRange(NSRange(location: max(line.location, sel.location + delta), length: 0))
    }

    /// ⌘B / ⌘I: wrap or unwrap the selection.
    func toggleWrap(_ marker: String) {
        let sel = selectedRange()
        let selected = (string as NSString).substring(with: sel)
        let new = MarkdownEditing.toggleWrap(selected, marker: marker)
        insertText(new, replacementRange: sel)
        if sel.length == 0 {
            setSelectedRange(NSRange(location: sel.location + (marker as NSString).length, length: 0))
        } else {
            setSelectedRange(NSRange(location: sel.location, length: (new as NSString).length))
        }
    }

    /// Re-applies Markdown styling to the whole document.
    func restyle() {
        guard let storage = textStorage else { return }
        let spans = MarkdownStyler.spans(storage.string)
        storage.beginEditing()
        MarkdownTheme.apply(spans, to: storage)
        storage.endEditing()
        typingAttributes = MarkdownTheme.base
    }
}

/// How each Markdown span looks: olympus DS tokens, Outfit for prose, Geist Mono for code.
enum MarkdownTheme {
    static let bodySize: CGFloat = 15

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 2
        return p
    }

    /// Frontmatter: tight lines, it is metadata rather than reading text.
    static var compact: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 0
        p.paragraphSpacing = 0
        return p
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: Theme.sans(bodySize), .foregroundColor: Theme.foreground, .paragraphStyle: paragraph]
    }

    private static let headingSizes: [CGFloat] = [26, 21, 18, 16, 15, 15]

    static func apply(_ spans: [StyledRange], to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes(base, range: all)
        let faint = Theme.mutedForeground.withAlphaComponent(0.5)
        for s in spans {
            let r = s.range
            guard r.upperBound <= storage.length else { continue }
            switch s.span {
            case .frontmatter:
                storage.addAttributes([.font: Theme.mono(11), .foregroundColor: Theme.mutedForeground.withAlphaComponent(0.8),
                                       .paragraphStyle: compact], range: r)
            case .heading(let level):
                storage.addAttribute(.font, value: Theme.sans(headingSizes[min(level, 6) - 1], 600), range: r)
            case .marker:
                storage.addAttribute(.foregroundColor, value: faint, range: r)
            case .bold:
                storage.addAttribute(.font, value: Theme.sans(size(storage, at: r.location), 650), range: r)
            case .italic:
                storage.addAttribute(.obliqueness, value: 0.14, range: r)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: Theme.mutedForeground], range: r)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: Theme.warn.withAlphaComponent(0.22), range: r)
            case .code:
                storage.addAttributes([.font: Theme.mono(13.5), .foregroundColor: Theme.chart1,
                                       .backgroundColor: NSColor.white.withAlphaComponent(0.06)], range: r)
            case .codeBlock:
                storage.addAttributes([.font: Theme.mono(13.5), .foregroundColor: Theme.foreground.withAlphaComponent(0.85)], range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: Theme.mutedForeground, range: r)
            case .rule:
                storage.addAttribute(.foregroundColor, value: faint, range: r)
            case .tag:
                storage.addAttributes([.foregroundColor: Theme.chart5,
                                       .backgroundColor: Theme.chart5.withAlphaComponent(0.12)], range: r)
            case .link(let target):
                storage.addAttributes([.foregroundColor: Theme.info, .hopLink: target], range: r)
            case .task(let done):
                storage.addAttributes([.font: Theme.mono(14, 500), .foregroundColor: done ? Theme.good : Theme.warn], range: r)
            case .doneText:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: Theme.mutedForeground], range: r)
            }
        }
    }

    private static func size(_ storage: NSTextStorage, at i: Int) -> CGFloat {
        (storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? bodySize
    }
}
