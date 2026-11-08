import AppKit

enum ResultLayout: Equatable {
    case list
    /// Items' `.emoji` icons in a grid; the selected item's title shows under it.
    case grid(columns: Int)
}

/// What a mode can ask of the launcher.
protocol LauncherContext: AnyObject {
    var query: String { get }
    /// Re-run `sections(for:)` with the current query (e.g. after async data arrives).
    func reload()
    /// Replace the search text and re-run the query.
    func setQuery(_ query: String)
    /// Re-read the mode's title, placeholder, secure input and accessory view.
    func refreshChrome()
    func push(_ mode: Mode)
    func pop()
    func dismiss()
    func showHUD(_ text: String)
    func setLoading(_ loading: Bool)
    /// Keep the panel open while a system dialog (Touch ID, auth, file picker) has focus.
    var suppressAutoHide: Bool { get set }
}

/// A screen of results. Root search is a mode; sub-modes (Uninstall, WireGuard,
/// KeePassXC) are pushed on top of it.
protocol Mode: AnyObject {
    /// Shown as a pill left of the search field; `nil` for root.
    var title: String? { get }
    /// Colour of the mode pill and the selection; nil uses the system accent.
    var tint: NSColor? { get }
    var placeholder: String { get }
    /// Secure text entry (for a password prompt mode).
    var isSecureInput: Bool { get }
    /// Optional control right of the search field (e.g. a folder filter).
    var accessoryView: NSView? { get }
    /// Rows, or a grid of large glyphs (emoji) where ←→↑↓ move.
    var layout: ResultLayout { get }

    func sections(for query: String) -> [ResultSection]
    func didEnter(_ context: LauncherContext)
    func didExit()
    /// Called when ↵ is pressed with no items (e.g. submit a password).
    func submit(_ query: String) -> ActionResult?
    /// Tab: a completed query (e.g. a path), or nil for the default Tab behaviour.
    func complete(_ query: String) -> String?
    /// The selected row changed (keys, mouse or a reload).
    func selectionDidChange(_ item: Item?)
}

extension Mode {
    var tint: NSColor? { nil }
    var isSecureInput: Bool { false }
    var accessoryView: NSView? { nil }
    var layout: ResultLayout { .list }
    func didEnter(_ context: LauncherContext) {}
    func didExit() {}
    func submit(_ query: String) -> ActionResult? { nil }
    func complete(_ query: String) -> String? { nil }
    func selectionDidChange(_ item: Item?) {}
}
