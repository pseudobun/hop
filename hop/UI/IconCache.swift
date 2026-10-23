import AppKit

/// Cache of file and symbol icons; only visible rows ask for icons. File icons are
/// flattened to small bitmaps (~8 KB each), so a few hundred apps stay cheap.
final class IconCache {
    static let shared = IconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    func image(for icon: ItemIcon?, size: CGFloat = 22) -> NSImage? {
        guard let icon else { return nil }
        switch icon {
        case .file(let path):
            let key = "file:\(path)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = Self.bitmap(NSWorkspace.shared.icon(forFile: path), size: size)
            cache.setObject(img, forKey: key)
            return img
        case .symbol(let name, _):
            let key = "sym:\(name)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.72, weight: .regular)
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            if let img { cache.setObject(img, forKey: key) }
            return img
        case .image(let img):
            return img
        case .tile(let name, let color):
            let key = "tile:\(name):\(color.description)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = Self.tile(name, color, size: size)
            cache.setObject(img, forKey: key)
            return img
        case .emoji(let e):
            let key = "emoji:\(e)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let font = NSFont.systemFont(ofSize: size * 0.8)
                let str = NSAttributedString(string: e, attributes: [.font: font])
                let s = str.size()
                str.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
                return true
            }
            cache.setObject(img, forKey: key)
            return img
        }
    }

    func purge() { cache.removeAllObjects() }

    private var prewarmTask: Task<Void, Never>?

    /// Renders icons ahead of time, a few per main-actor turn with a pause in between,
    /// so neither the first show nor the first matches render icons while the user waits.
    func prewarm(_ icons: [ItemIcon]) {
        prewarmTask?.cancel()
        prewarmTask = Task {
            for (n, icon) in icons.enumerated() {
                guard !Task.isCancelled else { return }
                _ = image(for: icon)
                if n % 8 == 7 { try? await Task.sleep(for: .milliseconds(2)) }
            }
        }
    }

    /// Renders the best representation once; drawing a workspace icon directly goes
    /// through IconServices (and a placeholder pass in NSImageView) every time.
    private static func bitmap(_ icon: NSImage, size: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var rect = NSRect(x: 0, y: 0, width: size * scale, height: size * scale)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    private static func tile(_ symbol: String, _ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            color.withAlphaComponent(0.16).setFill()
            path.fill()
            color.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
