import AppKit

/// Results as a grid of large glyphs under micro-label section headings, with the selected
/// item's name in a line below. The launcher swaps it in for the table when a mode's
/// layout is `.grid`; ←→ move by one cell, ↑↓ by a row, keeping the column.
final class GridResultsView: NSView {
    var onSelectionChange: (() -> Void)?
    /// A click on a cell: run its primary action.
    var onActivate: ((Item) -> Void)?

    private let scroll = NSScrollView()
    private let canvas = GridCanvas()
    private let detailGlyph = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSubtitle = NSTextField(labelWithString: "")
    static let detailHeight: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        canvas.onClick = { [weak self] i in
            guard let self else { return }
            select(i)
            if let item = selectedItem { onActivate?(item) }
        }

        detailGlyph.font = .systemFont(ofSize: 18)
        detailTitle.font = Theme.body
        detailTitle.textColor = Theme.foreground
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentHuggingPriority(.required, for: .horizontal)
        detailSubtitle.font = Theme.meta
        detailSubtitle.textColor = Theme.mutedForeground
        detailSubtitle.lineBreakMode = .byTruncatingTail
        detailSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSStackView(views: [detailGlyph, detailTitle, detailSubtitle])
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let rule = NSBox()
        rule.boxType = .separator

        for v in [scroll, rule, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: detail.topAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.heightAnchor.constraint(equalToConstant: Self.detailHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { canvas.items.isEmpty }

    var selectedItem: Item? { canvas.selected.map { canvas.items[$0] } }

    /// Replaces the content; keeps the item with `keepingID` selected when it is still there.
    func show(_ sections: [ResultSection], columns: Int, tint: NSColor?, keepingID: String?) {
        canvas.tint = tint ?? Theme.info
        canvas.columns = columns
        canvas.setSections(sections.filter { !$0.items.isEmpty })
        canvas.frame.size.width = scroll.contentSize.width
        canvas.relayout()
        let kept = keepingID.flatMap { id in canvas.items.firstIndex { $0.id == id } }
        select(kept ?? (canvas.items.isEmpty ? nil : 0), scrollToTop: kept == nil)
    }

    func move(columns step: Int) {
        guard let s = canvas.selected else { return select(canvas.items.isEmpty ? nil : 0) }
        select(min(max(0, s + step), canvas.items.count - 1))
    }

    func move(rows step: Int) {
        guard let s = canvas.selected else { return select(canvas.items.isEmpty ? nil : 0) }
        let row = canvas.rowOf[s], target = row + step
        guard target >= 0, target < canvas.rows.count else {
            // Past the last row: the last item; above the first: the first.
            return select(step > 0 ? canvas.items.count - 1 : 0)
        }
        let column = s - canvas.rows[row].lowerBound
        let r = canvas.rows[target]
        select(min(r.lowerBound + column, r.upperBound - 1))
    }

    private func select(_ i: Int?, scrollToTop: Bool = false) {
        canvas.selected = i
        if scrollToTop {
            canvas.scroll(.zero)
        } else if let i {
            // The heading stays in view above a section's first row.
            var rect = canvas.cellRects[i].insetBy(dx: 0, dy: -6)
            if let h = canvas.headerAbove(i) { rect = rect.union(h) }
            canvas.scrollToVisible(rect)
        }
        let item = i.map { canvas.items[$0] }
        if case .emoji(let e) = item?.icon { detailGlyph.stringValue = e } else { detailGlyph.stringValue = "" }
        detailTitle.stringValue = item?.title ?? ""
        detailSubtitle.stringValue = item?.subtitle ?? ""
        onSelectionChange?()
    }

    override func layout() {
        super.layout()
        if canvas.frame.width != scroll.contentSize.width {
            canvas.frame.size.width = scroll.contentSize.width
            canvas.relayout()
        }
    }
}

/// One view draws every cell: ~1900 emoji as subviews would cost more than they show.
private final class GridCanvas: NSView {
    var columns = 9
    var tint = Theme.info
    var onClick: ((Int) -> Void)?
    private(set) var items: [Item] = []
    private(set) var cellRects: [NSRect] = []
    /// Item ranges of each visual row, and each item's row.
    private(set) var rows: [Range<Int>] = []
    private(set) var rowOf: [Int] = []
    private var sections: [(title: String?, range: Range<Int>)] = []
    private var headers: [(title: String, rect: NSRect)] = []
    private var glyphs: [String] = []

    var selected: Int? {
        didSet {
            guard selected != oldValue else { return }
            for i in [oldValue, selected].compactMap({ $0 }) where i < cellRects.count { setNeedsDisplay(cellRects[i]) }
        }
    }

    private static let inset: CGFloat = 12
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 64
    private static let glyphFont = NSFont.systemFont(ofSize: 34)

    override var isFlipped: Bool { true }

    func setSections(_ sections: [ResultSection]) {
        var items: [Item] = []
        var ranges: [(String?, Range<Int>)] = []
        for s in sections {
            ranges.append((s.title, items.count..<items.count + s.items.count))
            items += s.items
        }
        self.items = items
        self.sections = ranges
        glyphs = items.map { if case .emoji(let e) = $0.icon { e } else { String($0.title.prefix(1)) } }
        selected = nil
    }

    func relayout() {
        let width = max(bounds.width, 1)
        let cell = (width - 2 * Self.inset) / CGFloat(columns)
        var y: CGFloat = 0
        var rects: [NSRect] = []
        var headers: [(String, NSRect)] = []
        var rows: [Range<Int>] = []
        var rowOf: [Int] = []
        rects.reserveCapacity(items.count)
        for s in sections {
            if let t = s.title {
                headers.append((t, NSRect(x: 0, y: y, width: width, height: Self.headerHeight)))
                y += Self.headerHeight
            }
            var i = s.range.lowerBound
            while i < s.range.upperBound {
                let end = min(i + columns, s.range.upperBound)
                for j in i..<end {
                    rects.append(NSRect(x: Self.inset + CGFloat(j - i) * cell, y: y, width: cell, height: Self.rowHeight))
                    rowOf.append(rows.count)
                }
                rows.append(i..<end)
                y += Self.rowHeight
                i = end
            }
            y += 4
        }
        cellRects = rects
        self.headers = headers
        self.rows = rows
        self.rowOf = rowOf
        let height = max(y, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != height { frame.size.height = height }
        needsDisplay = true
    }

    /// The heading right above item `i` when it sits in its section's first row.
    func headerAbove(_ i: Int) -> NSRect? {
        guard i < cellRects.count else { return nil }
        let top = cellRects[i].minY
        return headers.first { abs($0.rect.maxY - top) < 0.5 }?.rect
    }

    override func draw(_ dirtyRect: NSRect) {
        for h in headers where h.rect.intersects(dirtyRect) {
            let label = Theme.labelString(h.title)
            let size = label.size()
            let y = h.rect.maxY - 6 - size.height
            label.draw(at: NSPoint(x: 20, y: y))
            Theme.border.setFill()
            NSRect(x: 20 + size.width + 10, y: (y + size.height / 2).rounded(), width: h.rect.width - size.width - 50, height: 1).fill()
        }
        // Rows are in order: start at the first that can reach the dirty rect.
        var lo = 0, hi = cellRects.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cellRects[mid].maxY < dirtyRect.minY { lo = mid + 1 } else { hi = mid }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.glyphFont]
        for i in lo..<cellRects.count {
            let r = cellRects[i]
            if r.minY > dirtyRect.maxY { break }
            guard r.intersects(dirtyRect) else { continue }
            if i == selected {
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
                tint.withAlphaComponent(0.14).setFill()
                path.fill()
                tint.withAlphaComponent(0.28).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            let glyph = glyphs[i] as NSString
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded()), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cellRects.firstIndex(where: { $0.contains(p) }) { onClick?(i) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
