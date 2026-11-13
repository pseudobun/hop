import AppKit

/// The selected row's rounded highlight as one layer under the rows, gliding from row to row
/// instead of each row drawing its own. Rows using it set `ResultRowView.drawsSelection = false`.
/// The highlight is a plain CALayer in a layer-hosting view, so AppKit never syncs or redraws it:
/// a move is one property change and the render server animates it.
final class SelectionGlide {
    private let host = Host()
    private weak var table: NSTableView?
    private var shownRow: Int?

    var tint: NSColor = Theme.info {
        didSet { if tint != oldValue { host.paint(tint) } }
    }

    init(table: NSTableView) {
        self.table = table
        host.paint(tint)
        host.frame = table.bounds
        host.autoresizingMask = [.width, .height]
        table.addSubview(host, positioned: .below, relativeTo: nil)
    }

    /// Moves the highlight to the table's selected row: gliding when `animated` and it was
    /// already on another row, otherwise in place at once.
    func sync(animated: Bool) {
        guard let table else { return }
        let bar = host.bar
        let row = table.selectedRow
        guard row >= 0, row < table.numberOfRows else {
            bar.isHidden = true
            shownRow = nil
            return
        }
        // Rows are added after the host; keep it the bottom subview, the table's size.
        if table.subviews.first !== host { table.addSubview(host, positioned: .below, relativeTo: nil) }
        if host.frame != table.bounds { host.frame = table.bounds }
        let frame = table.rect(ofRow: row).insetBy(dx: 8, dy: 1)
        // Already there (or gliding there): leave a glide in flight alone.
        if row == shownRow, bar.frame == frame, !bar.isHidden { return }
        let glide = animated && Motion.allowed && shownRow != nil && shownRow != row && !bar.isHidden
        shownRow = row
        // Start from wherever it is on screen, so key repeat chains smoothly instead of jumping.
        let from = glide ? (bar.presentation() ?? bar) : nil
        let fromPosition = from?.position, fromBounds = from?.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.removeAnimation(forKey: "glide")
        bar.frame = frame
        bar.isHidden = false
        CATransaction.commit()
        guard let fromPosition, let fromBounds else { return }
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPosition)
        position.toValue = NSValue(point: bar.position)
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: fromBounds)
        bounds.toValue = NSValue(rect: bar.bounds)
        let group = CAAnimationGroup()
        group.animations = [position, bounds]
        group.duration = 0.16
        group.timingFunction = Motion.glideTiming
        bar.add(group, forKey: "glide")
    }

    /// Layer-hosting: its layer tree is ours, top-down like the table.
    private final class Host: NSView {
        let bar = CALayer()

        init() {
            super.init(frame: .zero)
            let root = CALayer()
            root.isGeometryFlipped = true
            layer = root
            wantsLayer = true
            // On glass rounder and continuous, concentric with the window's corners.
            bar.cornerRadius = Glass.enabled ? 10 : 8
            bar.cornerCurve = Glass.enabled ? .continuous : .circular
            bar.borderWidth = 0.5
            bar.isHidden = true
            root.addSublayer(bar)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            bar.contentsScale = window?.backingScaleFactor ?? 2
        }

        func paint(_ tone: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if Glass.enabled {
                // A brighter, lit pill that reads on any wallpaper behind the glass.
                bar.backgroundColor = tone.withAlphaComponent(0.22).cgColor
                bar.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            } else {
                bar.backgroundColor = tone.withAlphaComponent(0.14).cgColor
                bar.borderColor = tone.withAlphaComponent(0.28).cgColor
            }
            CATransaction.commit()
        }
    }
}
