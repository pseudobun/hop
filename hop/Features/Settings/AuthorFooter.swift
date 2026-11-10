import AppKit

/// The footer of the About page: "Made with ❤️ by pseudobun", the author's links as logos,
/// and (for public apps) a line saying the app stays open source. The same file lives in paw
/// and hop.
enum AuthorFooter {
    struct Style {
        let foreground: NSColor
        let muted: NSColor
        let line: NSColor
        let font: (CGFloat, CGFloat) -> NSFont
    }

    struct Link {
        let name: String
        let url: String
        let image: NSImage
    }

    static let links: [Link] = [
        Link(name: "pseudobun.dev", url: "https://pseudobun.dev", image: symbol("globe")),
        Link(name: "GitHub", url: "https://github.com/pseudobun", image: svg(Logo.github, viewBox: 16)),
        Link(name: "X", url: "https://x.com/pseudourban", image: svg(Logo.x, viewBox: 24)),
        Link(name: "Email", url: "mailto:urban@bunnys.cloud", image: symbol("envelope")),
    ]

    /// `openSource`: the app's name and repository, for the line under the divider.
    static func make(width: CGFloat, style: Style, openSource: (app: String, repo: String)? = nil) -> NSView {
        let made = NSTextField(labelWithString: "Made with ❤️ by")
        made.font = style.font(12, 400)
        made.textColor = style.muted
        let name = NSTextField(labelWithString: "pseudobun")
        name.font = style.font(17, 600)
        name.textColor = style.foreground

        let icons = NSStackView(views: links.map { link in
            let b = LinkButton(url: link.url)
            b.image = link.image
            b.image?.size = NSSize(width: 16, height: 16)
            b.imageScaling = .scaleProportionallyUpOrDown
            b.contentTintColor = style.foreground
            b.toolTip = link.name
            b.setAccessibilityLabel(link.name)
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return b
        })
        icons.spacing = 22

        var views: [NSView] = [made, name, icons]
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 12, right: 0)

        if let openSource {
            let divider = NSBox()
            divider.boxType = .custom
            divider.borderWidth = 0
            divider.fillColor = style.line
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            divider.widthAnchor.constraint(equalToConstant: (width * 0.5).rounded()).isActive = true
            let button = LinkButton(url: openSource.repo)
            button.image = symbol("chevron.left.forwardslash.chevron.right")
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: "  \(openSource.app) is and will remain open source",
                                                        attributes: [.font: style.font(11, 400), .foregroundColor: style.muted])
            button.contentTintColor = style.muted
            button.toolTip = openSource.repo
            views += [divider, button]
        }
        views.forEach(column.addArrangedSubview)
        column.setCustomSpacing(2, after: made)
        column.setCustomSpacing(12, after: name)
        if views.count > 3 {
            column.setCustomSpacing(16, after: icons)
            column.setCustomSpacing(12, after: views[3])
        }

        let wrap = NSStackView(views: [column])
        wrap.alignment = .centerX
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.widthAnchor.constraint(equalToConstant: width).isActive = true
        return wrap
    }

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    /// A one-colour logo from SVG path data, tinted like a symbol.
    private static func svg(_ path: String, viewBox: Int) -> NSImage {
        let doc = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(viewBox) \(viewBox)\"><path fill=\"black\" d=\"\(path)\"/></svg>"
        let image = NSImage(data: Data(doc.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private enum Logo {
        /// GitHub's mark (Octicons `mark-github`, 16 × 16).
        static let github = "M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"
        /// The X logo (24 × 24).
        static let x = "M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"
    }
}

/// A borderless button that opens a URL, with a pointing-hand cursor.
private final class LinkButton: NSButton {
    private var url = ""

    convenience init(url: String) {
        self.init(frame: .zero)
        self.url = url
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(open)
    }

    @objc private func open() {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
