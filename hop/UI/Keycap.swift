import AppKit

/// "Title [⌘K]" with the keys drawn as a small rounded keycap.
enum Keycap {
    static func label(_ title: String, keys: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title + "  ", attributes: [
            .font: Theme.meta, .foregroundColor: Theme.mutedForeground,
        ])
        let cap = NSTextAttachment()
        cap.image = image(keys)
        cap.bounds = NSRect(x: 0, y: -4, width: cap.image!.size.width, height: cap.image!.size.height)
        s.append(NSAttributedString(attachment: cap))
        return s
    }

    static func image(_ keys: String) -> NSImage {
        let font = Theme.mono(11, 500)
        let text = NSAttributedString(string: keys, attributes: [.font: font, .foregroundColor: Theme.foreground])
        let t = text.size()
        let size = NSSize(width: ceil(t.width) + 10, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            Theme.foreground.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            text.draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2))
            return true
        }
    }
}
