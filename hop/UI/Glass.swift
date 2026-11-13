import AppKit

/// hop's window surfaces: macOS 26 Liquid Glass (`general.glass`, on by default) or the flat,
/// mostly opaque dark look. Changing the setting rebuilds the windows as a theme change does.
enum Glass {
    nonisolated(unsafe) static var enabled = true
    /// `general.glassStyle`: frosted (Spotlight) or clear.
    nonisolated(unsafe) static var style: NSGlassEffectView.Style = .regular
    /// `general.glassTint` as 0…1: how much of the theme's background tints the glass.
    nonisolated(unsafe) static var tint: CGFloat = 0.2

    /// The glass settings of `general`, to tell when windows must be rebuilt.
    static func signature(_ general: HopConfig.General) -> String {
        general.glass ? "\(general.glassStyle):\(general.glassTint)" : "off"
    }

    /// What the windows were built with (`signature` of the applied config).
    nonisolated(unsafe) static var current = "regular:20"

    /// Takes the glass settings from the config; true when they changed.
    @discardableResult
    static func configure(_ general: HopConfig.General) -> Bool {
        let next = signature(general)
        defer { current = next }
        enabled = general.glass
        style = general.glassStyle == "clear" ? .clear : .regular
        tint = CGFloat(min(max(general.glassTint, 0), 100)) / 100
        return next != current
    }

    /// A window's backdrop. Set `root` as the window's content view and build in `content`.
    /// `dense` keeps more of the theme's colour behind the content, for windows of long text
    /// (notes) that must stay readable over any wallpaper.
    static func surface(cornerRadius: CGFloat, dense: Bool = false) -> (root: NSGlassEffectView, content: NSView) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = cornerRadius
        if enabled {
            glass.style = style
            // The glass itself keeps text legible (it adapts to what is behind); the theme only
            // tints it, as much as `general.glassTint` says.
            glass.tintColor = Theme.background.withAlphaComponent(tint)
            // A veil over the glass darkens (or lightens) it further at higher tints. Clear glass
            // barely frosts, so it gets a little more; long text (notes) keeps a floor.
            var veil = tint * (style == .clear ? 0.75 : 0.5)
            if dense { veil = max(veil, 0.3) }
            content.layer?.backgroundColor = veil > 0 ? Theme.background.withAlphaComponent(veil).cgColor : nil
        } else {
            // DS surfaces are dark and quiet: a mostly opaque theme background over the glass.
            glass.tintColor = Theme.background.withAlphaComponent(0.78)
            content.layer?.backgroundColor = Theme.background.withAlphaComponent(dense ? 0.86 : 0.82).cgColor
        }
        glass.contentView = content
        return (glass, content)
    }

    /// The HUD's tint: lighter on glass.
    static var hudTint: NSColor { Theme.background.withAlphaComponent(enabled ? max(tint, 0.15) : 0.78) }

    /// A floating piece of glass inside a window (the ⌘K action panel), filling `view` behind
    /// its subviews; nil without glass, where the view paints its own card.
    @discardableResult
    static func backing(_ view: NSView, cornerRadius: CGFloat) -> NSGlassEffectView? {
        guard enabled else { return nil }
        let glass = NSGlassEffectView()
        glass.style = style
        glass.cornerRadius = cornerRadius
        // A touch more than the window under it, so the panel reads as its own piece.
        glass.tintColor = Theme.card.withAlphaComponent(min(tint + 0.15, 1))
        glass.frame = view.bounds
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass, positioned: .below, relativeTo: nil)
        return glass
    }
}
