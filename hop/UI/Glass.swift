import AppKit

/// hop's window surfaces: macOS 26 Liquid Glass (`general.glass`, on by default) or the flat,
/// mostly opaque dark look. Changing the setting rebuilds the windows as a theme change does.
enum Glass {
    nonisolated(unsafe) static var enabled = true

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
            glass.style = .regular
            // Tinted with the theme so text keeps its contrast; the wallpaper still shows through.
            glass.tintColor = Theme.background.withAlphaComponent(Theme.isLight ? 0.45 : 0.6)
            // The tint alone barely darkens it; a light veil keeps muted text readable over
            // bright wallpapers while the colours behind still come through.
            let veil: CGFloat = dense ? 0.6 : (Theme.isLight ? 0.3 : 0.4)
            content.layer?.backgroundColor = Theme.background.withAlphaComponent(veil).cgColor
        } else {
            // DS surfaces are dark and quiet: a mostly opaque theme background over the glass.
            glass.tintColor = Theme.background.withAlphaComponent(0.78)
            content.layer?.backgroundColor = Theme.background.withAlphaComponent(dense ? 0.86 : 0.82).cgColor
        }
        glass.contentView = content
        return (glass, content)
    }

    /// The HUD's tint: lighter on glass.
    static var hudTint: NSColor { Theme.background.withAlphaComponent(enabled ? 0.55 : 0.78) }

    /// A floating piece of glass inside a window (the ⌘K action panel), filling `view` behind
    /// its subviews; nil without glass, where the view paints its own card.
    @discardableResult
    static func backing(_ view: NSView, cornerRadius: CGFloat) -> NSGlassEffectView? {
        guard enabled else { return nil }
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.tintColor = Theme.card.withAlphaComponent(Theme.isLight ? 0.45 : 0.6)
        glass.frame = view.bounds
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass, positioned: .below, relativeTo: nil)
        return glass
    }
}
