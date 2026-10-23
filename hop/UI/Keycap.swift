import AppKit

/// "Title [⌘K]" with the keys drawn as a small rounded keycap.
enum Keycap {
    private struct LabelKey: Hashable {
        let title: String
        let keys: String
    }

    // The footer is relabelled on every selection change, so keep what was built.
    private static var images: [String: NSImage] = [:]
    private static var labels: [LabelKey: NSAttributedString] = [:]

    static func label(_ title: String, keys: String) -> NSAttributedString {
        let key = LabelKey(title: title, keys: keys)
        if let cached = labels[key] { return cached }
        let s = NSMutableAttributedString(string: title + "  ", attributes: [
            .font: Theme.meta, .foregroundColor: Theme.mutedForeground,
        ])
        let cap = NSTextAttachment()
        let img = image(keys)
        cap.image = img
        cap.bounds = NSRect(x: 0, y: -4, width: img.size.width, height: img.size.height)
        s.append(NSAttributedString(attachment: cap))
        labels[key] = s
        return s
    }

    static func image(_ keys: String) -> NSImage {
        if let cached = images[keys] { return cached }
        let font = Theme.mono(11, 500)
        let text = NSAttributedString(string: keys, attributes: [.font: font, .foregroundColor: Theme.foreground])
        let t = text.size()
        let size = NSSize(width: ceil(t.width) + 10, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            Theme.foreground.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            text.draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2))
            return true
        }
        images[keys] = img
        return img
    }
}
