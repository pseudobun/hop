import AppKit

/// One ring on screen: the root ring, or a group or fan opened from it.
struct RingLevel {
    var title: String
    var nodes: [RingNode]
    var layout: RingLayout
    var states: [Bool?]
}

/// A transparent panel over the pointer's screen; it never takes clicks or focus.
final class RingPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = Theme.appearance
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the levels in screen coordinates shifted to the panel.
final class RingView: NSView {
    var levels: [RingLevel] = []
    var aimed: Int?
    var pointer: CGPoint = .zero
    /// 0…1 while the ring opens.
    var appear: CGFloat = 1
    var scale: CGFloat = 1
    var digits = true
    var origin: CGPoint = .zero

    override var isFlipped: Bool { false }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (depth, level) in levels.enumerated() {
            let top = depth == levels.count - 1
            ctx.saveGState()
            ctx.setAlpha((top ? 1 : 0.35) * appear)
            draw(level, top: top, in: ctx)
            ctx.restoreGState()
        }
    }

    private func draw(_ level: RingLevel, top: Bool, in ctx: CGContext) {
        let l = level.layout
        let c = local(l.center)
        let grow = 0.82 + 0.18 * appear
        let fan = l.facing != nil
        // Center disc with the aimed slice's name; a group's fan has none.
        let hub = 34 * scale * grow
        if !fan {
            let hubRect = CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)
            Theme.background.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: hubRect).fill()
            Theme.border.setStroke()
            let ring = NSBezierPath(ovalIn: hubRect)
            ring.lineWidth = 1
            ring.stroke()
        }
        if top && !fan {
            // Direction of the pointer, a short arc on the hub's edge.
            let dx = pointer.x - l.center.x, dy = pointer.y - l.center.y
            if hypot(dx, dy) > l.deadZone {
                let a = atan2(dy, dx) * 180 / .pi
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: hub - 2, startAngle: a - 22, endAngle: a + 22)
                arc.lineWidth = 3
                arc.lineCapStyle = .round
                Theme.primary.setStroke()
                arc.stroke()
            }
            let name = aimed.flatMap { $0 < level.nodes.count ? level.nodes[$0].title : nil } ?? level.title
            drawText(name, at: c, width: hub * 1.8, size: 11 * scale, weight: .semibold, color: Theme.foreground)
        }
        for (i, node) in level.nodes.enumerated() {
            let p0 = local(l.position(i))
            let p = CGPoint(x: c.x + (p0.x - c.x) * grow, y: c.y + (p0.y - c.y) * grow)
            let hot = top && aimed == i
            let r = l.bubble * (hot ? 1.16 : 1)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let broken: Bool = { if case .broken = node.kind { true } else { false } }()
            ctx.saveGState()
            if broken { ctx.setAlpha(0.45 * appear) }
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: hot ? 10 : 5, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            (hot ? (node.tint ?? Theme.primary) : Theme.card).setFill()
            NSBezierPath(ovalIn: rect).fill()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            (hot ? Theme.primary : Theme.border).setStroke()
            let outline = NSBezierPath(ovalIn: rect)
            outline.lineWidth = hot ? 2 : 1
            outline.stroke()
            if node.isGroup {
                // Groups wear an outer arc on their far side: flick on through it.
                let a = atan2(p.y - c.y, p.x - c.x) * 180 / .pi
                let arc = NSBezierPath()
                arc.appendArc(withCenter: p, radius: r + 4, startAngle: a - 50, endAngle: a + 50)
                arc.lineWidth = 2
                Theme.mutedForeground.setStroke()
                arc.stroke()
            }
            drawIcon(node, in: rect.insetBy(dx: r * 0.42, dy: r * 0.42), hot: hot)
            if i < level.states.count, let state = level.states[i] {
                let d = 7 * scale
                let dot = CGRect(x: rect.maxX - d * 1.3, y: rect.maxY - d * 1.3, width: d, height: d)
                let path = NSBezierPath(ovalIn: dot)
                if state { Theme.good.setFill(); path.fill() } else { path.lineWidth = 1.2; Theme.mutedForeground.setStroke(); path.stroke() }
            }
            if digits && top && i < 8 {
                drawText("\(i + 1)", at: CGPoint(x: rect.minX + 4 * scale, y: rect.maxY - 4 * scale), width: 12 * scale,
                         size: 8 * scale, weight: .medium, color: hot ? .white.withAlphaComponent(0.8) : Theme.mutedForeground)
            }
            // Name on a small mat under the bubble, readable on any wallpaper. In a group's fan only
            // the aimed one, outside the bubble, so the names don't pile up.
            if top && (!fan || hot) {
                let label = node.title as NSString
                let font = NSFont.systemFont(ofSize: 10 * scale, weight: hot ? .semibold : .regular)
                let size = label.size(withAttributes: [.font: font])
                let w = min(size.width + 10 * scale, 110 * scale), h = size.height + 3 * scale
                var mat = CGRect(x: p.x - w / 2, y: rect.minY - h - 3 * scale, width: w, height: h)
                if fan {
                    let a = atan2(p.y - c.y, p.x - c.x), out = r + h + 2 * scale
                    let q = CGPoint(x: p.x + cos(a) * out + cos(a) * w * 0.35, y: p.y + sin(a) * out)
                    mat = CGRect(x: q.x - w / 2, y: q.y - h / 2, width: w, height: h)
                }
                Theme.background.withAlphaComponent(0.86).setFill()
                NSBezierPath(roundedRect: mat, xRadius: h / 2, yRadius: h / 2).fill()
                drawText(node.title, at: CGPoint(x: mat.midX, y: mat.midY), width: w - 6 * scale, size: 10 * scale,
                         weight: hot ? .semibold : .regular, color: hot ? Theme.foreground : Theme.mutedForeground)
            }
            ctx.restoreGState()
        }
    }

    private func drawIcon(_ node: RingNode, in rect: CGRect, hot: Bool) {
        if let image = node.image {
            image.draw(in: rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18))
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
            .applying(.init(paletteColors: [hot ? .white : (node.tint ?? Theme.foreground)]))
        guard let image = (NSImage(systemSymbolName: node.symbol, accessibilityDescription: node.title)
                           ?? NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil))?
            .withSymbolConfiguration(config) else { return }
        let s = image.size
        let k = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * k, h = s.height * k
        image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private func drawText(_ text: String, at p: CGPoint, width: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                                                    .paragraphStyle: style]
        let s = text as NSString
        let h = s.size(withAttributes: attrs).height
        s.draw(in: CGRect(x: p.x - width / 2, y: p.y - h / 2, width: width, height: h), withAttributes: attrs)
    }
}
