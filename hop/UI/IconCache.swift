import AppKit

/// Small cache of file and symbol icons; only visible rows ask for icons.
final class IconCache {
    static let shared = IconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        return c
    }()

    func image(for icon: ItemIcon?, size: CGFloat = 22) -> NSImage? {
        guard let icon else { return nil }
        switch icon {
        case .file(let path):
            let key = "file:\(path)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: size, height: size)
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
