import AppKit

nonisolated struct NoteHeading: Equatable {
    let range: NSRange
    let level: Int
    let title: String

    static func parse(_ source: String) -> [NoteHeading] {
        let text = source as NSString
        return MarkdownStyler.spans(source).compactMap { span in
            guard case .heading(let level) = span.span else { return nil }
            let title = String(text.substring(with: span.range).dropFirst(level))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
            guard !title.isEmpty else { return nil }
            return NoteHeading(range: span.range, level: level, title: title)
        }
    }
}

extension NSAttributedString.Key {
    static let hopHeadingSource = NSAttributedString.Key("hopHeadingSource")
}

/// A compact, independently scrolling table of contents with a moving active rail.
final class NotesOutlineView: NSView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }
    var onSelect: ((Int) -> Void)?
    private let caption = NSTextField(labelWithAttributedString: Theme.labelString("ON THIS PAGE", color: Theme.mutedForeground))
    private let scroll = NSScrollView()
    private let document = Document()
    private let rail = NSView()
    private let marker = NSView()
    private var buttons: [NSButton] = []
    private var levels: [Int] = []
    private var active: Int?
    private let rowHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(caption)
        addSubview(scroll)
        for (view, color) in [(rail, Theme.border), (marker, Theme.foreground)] {
            view.wantsLayer = true
            view.layer?.backgroundColor = color.cgColor
            document.addSubview(view)
        }
        marker.isHidden = true
        setAccessibilityLabel("On this page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ headings: [NoteHeading]) {
        buttons.forEach { $0.removeFromSuperview() }
        levels = headings.map(\.level)
        active = nil
        marker.isHidden = true
        buttons = headings.enumerated().map { index, heading in
            let button = NSButton(title: NotesPreviewView.render(heading.title).string, target: self, action: #selector(selectHeading(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = Theme.sans(12)
            button.contentTintColor = Theme.mutedForeground
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
            document.addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 16, y: bounds.height - 28, width: max(0, bounds.width - 24), height: 16)
        scroll.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - 20), height: max(0, bounds.height - 48))
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(buttons.count) * rowHeight))
        rail.frame = NSRect(x: 0, y: 0, width: 1, height: CGFloat(buttons.count) * rowHeight)
        let base = levels.min() ?? 1
        for (index, button) in buttons.enumerated() {
            let x = CGFloat(levels[index] - base) * 10 + 10
            button.frame = NSRect(x: x, y: CGFloat(index) * rowHeight, width: max(0, document.bounds.width - x - 4), height: rowHeight)
        }
        if let active { marker.frame = markerFrame(active) }
    }

    func select(_ index: Int?, animated: Bool = true) {
        guard active != index else { return }
        let hadSelection = active != nil
        active = index
        for (i, button) in buttons.enumerated() {
            button.contentTintColor = i == index ? Theme.foreground : Theme.mutedForeground
            button.font = Theme.sans(12, i == index ? 600 : 400)
            button.setAccessibilityValue(i == index ? "Current section" : "")
        }
        marker.isHidden = index == nil
        guard let index, buttons.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && hadSelection && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            marker.animator().frame = markerFrame(index)
        }
        document.scrollToVisible(buttons[index].frame)
    }

    private func markerFrame(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * rowHeight + 3, width: 2, height: rowHeight - 6)
    }

    @objc private func selectHeading(_ sender: NSButton) { onSelect?(sender.tag) }
}
