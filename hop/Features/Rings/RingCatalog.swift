import AppKit

/// hop's built-in ring actions: id, name and symbol. `RingRunner` runs them; every one is
/// also a launcher command (`ring.<id>`).
nonisolated struct RingCatalogEntry: Sendable {
    enum Group: String, Sendable { case system = "System", finder = "Finder", media = "Media", windows = "Windows & Apps", agents = "Coding Agents" }

    let id: String
    let title: String
    let symbol: String
    let group: Group
    let detail: String
    /// A switch: the slice shows a dot, filled when on.
    var isSwitch = false
    /// Opens a fan of choices instead of running straight away.
    var isFan = false
}

nonisolated enum RingCatalog {
    static func entry(_ id: String) -> RingCatalogEntry? { byID[id.lowercased()] }

    private static let byID: [String: RingCatalogEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static let all: [RingCatalogEntry] = [
        // System
        .init(id: "dark-mode", title: "Dark Mode", symbol: "circle.lefthalf.filled", group: .system,
              detail: "Switch between light and dark appearance", isSwitch: true),
        .init(id: "night-shift", title: "Night Shift", symbol: "moon.haze.fill", group: .system,
              detail: "Turn Night Shift's warm tint on or off", isSwitch: true),
        .init(id: "keep-awake", title: "Keep Awake", symbol: "cup.and.saucer.fill", group: .system,
              detail: "Keep the Mac and its displays awake until you flip it back", isSwitch: true),
        .init(id: "mute", title: "Mute", symbol: "speaker.slash.fill", group: .system,
              detail: "Mute or unmute the sound output", isSwitch: true),
        .init(id: "mic-mute", title: "Mute Microphone", symbol: "mic.slash.fill", group: .system,
              detail: "Set the input volume to zero, and back to where it was", isSwitch: true),
        .init(id: "volume-up", title: "Volume Up", symbol: "speaker.wave.3.fill", group: .system, detail: "Raise the volume a step"),
        .init(id: "volume-down", title: "Volume Down", symbol: "speaker.wave.1.fill", group: .system, detail: "Lower the volume a step"),
        .init(id: "bluetooth", title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", group: .system,
              detail: "Turn Bluetooth on or off", isSwitch: true),
        .init(id: "lock-screen", title: "Lock Screen", symbol: "lock.fill", group: .system, detail: "Lock the screen now"),
        .init(id: "sleep", title: "Sleep", symbol: "powersleep", group: .system, detail: "Put the Mac to sleep now"),
        .init(id: "displays-off", title: "Displays Off", symbol: "display", group: .system,
              detail: "Turn the displays off; everything keeps running"),
        .init(id: "screen-saver", title: "Screen Saver", symbol: "sparkles.tv", group: .system, detail: "Start the screen saver"),
        .init(id: "input-source", title: "Next Keyboard Language", symbol: "globe", group: .system,
              detail: "Switch to the next keyboard input source"),
        .init(id: "input-sources", title: "Keyboard Languages", symbol: "keyboard", group: .system,
              detail: "Pick one of your keyboard input sources", isFan: true),
        .init(id: "eject-all", title: "Eject All Disks", symbol: "eject.fill", group: .system,
              detail: "Eject every ejectable disk and disk image"),
        .init(id: "hidden-files", title: "Hidden Files", symbol: "eye.slash", group: .system,
              detail: "Show or hide hidden files in Finder (restarts Finder)", isSwitch: true),
        .init(id: "file-extensions", title: "File Extensions", symbol: "doc.badge.ellipsis", group: .system,
              detail: "Show or hide every file extension in Finder (restarts Finder)", isSwitch: true),
        .init(id: "path-bar", title: "Finder Path Bar", symbol: "point.topleft.down.to.point.bottomright.curvepath", group: .system,
              detail: "Show or hide the path bar in Finder windows", isSwitch: true),
        .init(id: "desktop-icons", title: "Desktop Icons", symbol: "menubar.dock.rectangle", group: .system,
              detail: "Show or hide everything on the desktop (restarts Finder)", isSwitch: true),
        .init(id: "user-library", title: "User Library", symbol: "building.columns", group: .system,
              detail: "Show or hide ~/Library in Finder", isSwitch: true),
        .init(id: "dock-autohide", title: "Dock Auto Hide", symbol: "dock.rectangle", group: .system,
              detail: "Hide the Dock until the pointer reaches it", isSwitch: true),
        .init(id: "dock-recents", title: "Recent Apps in Dock", symbol: "clock.arrow.circlepath", group: .system,
              detail: "Show or hide the Dock's recent apps (restarts the Dock)", isSwitch: true),
        .init(id: "menu-bar-autohide", title: "Menu Bar Auto Hide", symbol: "menubar.rectangle", group: .system,
              detail: "Hide the menu bar until the pointer reaches it", isSwitch: true),
        .init(id: "clear-derived-data", title: "Clear DerivedData", symbol: "hammer", group: .system,
              detail: "Move Xcode's DerivedData to the Trash"),
        .init(id: "screenshot-tools", title: "Screenshot & Recording", symbol: "camera.viewfinder", group: .system, detail: "⇧⌘5"),
        .init(id: "screenshot-area", title: "Copy Area Screenshot", symbol: "viewfinder", group: .system, detail: "⌃⇧⌘4"),
        .init(id: "screenshot-screen", title: "Copy Screen", symbol: "rectangle.on.rectangle", group: .system, detail: "⌃⇧⌘3"),
        .init(id: "emoji-picker", title: "Emoji & Symbols", symbol: "face.smiling", group: .system, detail: "⌃⌘Space"),
        // Windows & apps
        .init(id: "mission-control", title: "Mission Control", symbol: "rectangle.3.group", group: .windows, detail: "Every window and Space"),
        .init(id: "app-windows", title: "App Windows", symbol: "macwindow.on.rectangle", group: .windows, detail: "The front app's windows"),
        .init(id: "show-desktop", title: "Show Desktop", symbol: "menubar.dock.rectangle.badge.record", group: .windows, detail: "Move windows aside"),
        .init(id: "previous-desktop", title: "Previous Desktop", symbol: "arrow.left.square", group: .windows, detail: "⌃←"),
        .init(id: "next-desktop", title: "Next Desktop", symbol: "arrow.right.square", group: .windows, detail: "⌃→"),
        .init(id: "previous-app", title: "Previous App", symbol: "arrow.uturn.backward", group: .windows,
              detail: "Back to the app you used before this one"),
        .init(id: "switch-app", title: "Switch App", symbol: "square.stack.3d.up", group: .windows,
              detail: "Pick one of the running apps", isFan: true),
        .init(id: "hide-others", title: "Hide Others", symbol: "eye.slash.circle", group: .windows,
              detail: "Hide every other app; flip again to bring them back", isSwitch: true),
        .init(id: "full-screen", title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right", group: .windows, detail: "⌃⌘F"),
        .init(id: "minimize", title: "Minimize", symbol: "minus.square", group: .windows, detail: "⌘M"),
        .init(id: "close-window", title: "Close Window", symbol: "xmark.square", group: .windows, detail: "⌘W"),
        .init(id: "hide-app", title: "Hide App", symbol: "eye.slash", group: .windows, detail: "⌘H"),
        .init(id: "quit-app", title: "Quit App", symbol: "power", group: .windows, detail: "⌘Q"),
        .init(id: "force-quit-app", title: "Force Quit App", symbol: "exclamationmark.octagon.fill", group: .windows,
              detail: "Force quit the app that was in front"),
        .init(id: "force-quit", title: "Force Quit…", symbol: "exclamationmark.octagon", group: .windows, detail: "⌥⌘Esc"),
        // Media
        .init(id: "play-pause", title: "Play / Pause", symbol: "playpause.fill", group: .media, detail: "Whatever the Mac is playing"),
        .init(id: "next-track", title: "Next Track", symbol: "forward.fill", group: .media, detail: "Skip ahead"),
        .init(id: "previous-track", title: "Previous Track", symbol: "backward.fill", group: .media, detail: "Back a track"),
        .init(id: "shuffle", title: "Shuffle", symbol: "shuffle", group: .media,
              detail: "Shuffle on or off in Music or Spotify", isSwitch: true),
        .init(id: "repeat", title: "Repeat", symbol: "repeat", group: .media, detail: "Repeat on or off in Music or Spotify", isSwitch: true),
        // Finder selection
        .init(id: "copy-path", title: "Copy Path", symbol: "link", group: .finder,
              detail: "Paths of the items selected in Finder, one per line"),
        .init(id: "copy-name", title: "Copy Name", symbol: "textformat", group: .finder, detail: "Name of the item selected in Finder"),
        .init(id: "copy-files", title: "Copy Files", symbol: "doc.on.clipboard", group: .finder,
              detail: "The selected Finder items, ready to paste in another folder"),
        .init(id: "airdrop", title: "AirDrop", symbol: "airplayaudio", group: .finder, detail: "Send the selected Finder items with AirDrop"),
        .init(id: "move-to", title: "Move to Folder…", symbol: "arrowshape.turn.up.right", group: .finder,
              detail: "Move the selected Finder items to a folder you pick; nothing is replaced"),
        .init(id: "copy-to", title: "Copy to Folder…", symbol: "plus.rectangle.on.folder", group: .finder,
              detail: "Copy the selected Finder items to a folder you pick; nothing is replaced"),
        .init(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", group: .finder,
              detail: "Convert the selected file to another format, saved next to it", isFan: true),
        .init(id: "compress", title: "Compress", symbol: "doc.zipper", group: .finder, detail: "Zip the selected Finder items"),
        .init(id: "new-folder", title: "New Folder", symbol: "folder.badge.plus", group: .finder, detail: "In the front Finder window"),
        .init(id: "show-info", title: "Get Info", symbol: "info.circle", group: .finder, detail: "Info window for the selected items"),
        .init(id: "open-terminal", title: "Open in Terminal", symbol: "terminal", group: .finder,
              detail: "The front Finder folder in Terminal"),
        .init(id: "open-vscode", title: "Open in VS Code", symbol: "chevron.left.forwardslash.chevron.right", group: .finder,
              detail: "The selected Finder items in Visual Studio Code"),
        // Coding agents
        .init(id: "claude-model", title: "Claude Code Model", symbol: "cpu", group: .agents,
              detail: "Switch the model of the Claude Code session in the front terminal", isFan: true),
    ]
}
