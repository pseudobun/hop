import Foundation

/// Rings hop ships: the Media ring and app rings for common apps. They use the same slice
/// strings as the config, so any of them can be copied into `rings.rings` and changed there.
nonisolated enum RingPresets {
    static let media = HopConfig.Ring(
        name: "Media", keepOpen: true,
        slices: ["play-pause", "next-track", "volume-up", "shuffle", "mute", "repeat", "volume-down", "previous-track"].map { .init(action: $0) })

    private static func s(_ title: String, _ icon: String, _ action: String) -> HopConfig.Slice {
        HopConfig.Slice(title: title, icon: icon, action: action)
    }

    static let apps: [HopConfig.Ring] = [
        HopConfig.Ring(name: "Safari", app: "com.apple.Safari", slices: [
            s("New Tab", "plus.square.on.square", "key:cmd+t"),
            s("Next Tab", "chevron.right.square", "key:ctrl+tab"),
            s("Copy Link", "link", #"applescript:tell application "Safari" to set the clipboard to (URL of current tab of front window as text)"#),
            s("Reading List", "eyeglasses", "key:ctrl+cmd+2"),
            s("Reopen Tab", "arrow.uturn.backward.square", "key:shift+cmd+t"),
            s("Previous Tab", "chevron.left.square", "key:ctrl+shift+tab"),
            s("History", "clock", "key:cmd+y"),
            s("Tab Overview", "square.grid.2x2", "key:shift+cmd+\\"),
        ]),
        HopConfig.Ring(name: "Chrome", app: "com.google.Chrome", slices: [
            s("New Tab", "plus.square.on.square", "key:cmd+t"),
            s("Next Tab", "chevron.right.square", "key:ctrl+tab"),
            s("Copy Link", "link", #"applescript:tell application "Google Chrome" to set the clipboard to (URL of active tab of front window as text)"#),
            s("Search Tabs", "magnifyingglass", "key:shift+cmd+a"),
            s("Reopen Tab", "arrow.uturn.backward.square", "key:shift+cmd+t"),
            s("Previous Tab", "chevron.left.square", "key:ctrl+shift+tab"),
            s("History", "clock", "key:cmd+y"),
            s("Bookmarks", "book", "key:alt+cmd+b"),
        ]),
        HopConfig.Ring(name: "Finder", app: "com.apple.finder", slices: [
            s("", "", "copy-path"),
            s("", "", "new-folder"),
            s("", "", "convert"),
            s("", "", "airdrop"),
            s("", "", "open-terminal"),
            s("", "", "hidden-files"),
            s("Go to Folder", "arrow.right.circle", "key:shift+cmd+g"),
            HopConfig.Slice(title: "More", icon: "ellipsis.circle", children: ["copy-files", "move-to", "copy-to", "compress", "show-info",
                                                                            "copy-name", "open-vscode", "path-bar"].map { .init(action: $0) }),
        ]),
        HopConfig.Ring(name: "Xcode", app: "com.apple.dt.Xcode", slices: [
            s("Run", "play.fill", "key:cmd+r"),
            s("Build", "hammer.fill", "key:cmd+b"),
            s("Test", "checkmark.diamond", "key:cmd+u"),
            s("Clean", "trash", "key:shift+cmd+k"),
            s("Stop", "stop.fill", "key:cmd+."),
            s("Open Quickly", "magnifyingglass", "key:shift+cmd+o"),
            s("Navigator", "sidebar.left", "key:cmd+0"),
            s("", "", "clear-derived-data"),
        ]),
        vscode("VS Code", "com.microsoft.VSCode"),
        vscode("Cursor", "com.todesktop.230313mzl4w4u92"),
        HopConfig.Ring(name: "Slack", app: "com.tinyspeck.slackmacgap", slices: [
            s("Quick Switcher", "arrow.left.arrow.right", "key:cmd+k"),
            s("Unreads", "tray.full", "key:shift+cmd+a"),
            s("Threads", "bubble.left.and.bubble.right", "key:shift+cmd+t"),
            s("DMs", "person.2", "key:shift+cmd+k"),
            s("Search", "magnifyingglass", "key:cmd+g"),
            s("Next Unread", "arrow.down.circle", "key:alt+shift+down"),
            s("Previous Unread", "arrow.up.circle", "key:alt+shift+up"),
            s("Back", "chevron.backward", "key:cmd+["),
        ]),
        HopConfig.Ring(name: "Linear", app: "com.linear", slices: [
            s("New Issue", "square.and.pencil", "key:c"),
            s("Command Menu", "command", "key:cmd+k"),
            s("Assign to Me", "person.crop.circle", "key:i"),
            s("Status", "circle.dashed", "key:s"),
            s("Priority", "chart.bar", "key:p"),
            s("Copy Branch", "arrow.triangle.branch", "key:shift+cmd+."),
            s("Copy Link", "link", "key:shift+cmd+,"),
            s("Search", "magnifyingglass", "key:/"),
        ]),
        HopConfig.Ring(name: "Zoom", app: "us.zoom.xos", slices: [
            s("Mute", "mic.slash", "key:shift+cmd+a"),
            s("Video", "video", "key:shift+cmd+v"),
            s("Share Screen", "rectangle.on.rectangle", "key:shift+cmd+s"),
            s("Participants", "person.3", "key:cmd+u"),
            s("Chat", "bubble.left", "key:shift+cmd+h"),
            s("Raise Hand", "hand.raised", "key:alt+y"),
            s("Leave", "phone.down", "key:cmd+w"),
        ]),
        HopConfig.Ring(name: "Obsidian", app: "md.obsidian", slices: [
            s("Command Palette", "command", "key:cmd+p"),
            s("Quick Switcher", "arrow.left.arrow.right", "key:cmd+o"),
            s("New Note", "square.and.pencil", "key:cmd+n"),
            s("Search", "magnifyingglass", "key:shift+cmd+f"),
            s("Back", "chevron.backward", "key:alt+cmd+left"),
            s("Forward", "chevron.forward", "key:alt+cmd+right"),
        ]),
        HopConfig.Ring(name: "Things", app: "com.culturedcode.ThingsMac", slices: [
            s("New To-Do", "plus.circle", "key:cmd+n"),
            s("Inbox", "tray", "key:cmd+1"),
            s("Today", "star", "key:cmd+2"),
            s("Upcoming", "calendar", "key:cmd+3"),
            s("Anytime", "square.stack", "key:cmd+4"),
            s("Search", "magnifyingglass", "key:cmd+f"),
        ]),
        terminal("Ghostty", "com.mitchellh.ghostty", splits: true),
        terminal("Terminal", "com.apple.Terminal", splits: false),
        terminal("iTerm2", "com.googlecode.iterm2", splits: true),
    ]

    private static func vscode(_ name: String, _ id: String) -> HopConfig.Ring {
        HopConfig.Ring(name: name, app: id, slices: [
            s("Command Palette", "command", "key:shift+cmd+p"),
            s("Quick Open", "doc.text.magnifyingglass", "key:cmd+p"),
            s("Terminal", "terminal", "key:ctrl+`"),
            s("Find in Files", "magnifyingglass", "key:shift+cmd+f"),
            s("Go to Definition", "arrow.turn.down.right", "key:f12"),
            s("Sidebar", "sidebar.left", "key:cmd+b"),
            s("Debug", "ladybug", "key:f5"),
            s("New Window", "macwindow.badge.plus", "key:shift+cmd+n"),
        ])
    }

    private static func terminal(_ name: String, _ id: String, splits: Bool) -> HopConfig.Ring {
        var slices = [
            s("New Tab", "plus.square.on.square", "key:cmd+t"),
            s("Next Tab", "chevron.right.square", "key:shift+cmd+]"),
            s("", "", "claude-model"),
            s("Previous Tab", "chevron.left.square", "key:shift+cmd+["),
            s("Clear", "eraser", "key:cmd+k"),
            s("Close", "xmark.square", "key:cmd+w"),
        ]
        if splits {
            slices.insert(s("Split Right", "rectangle.split.2x1", "key:cmd+d"), at: 1)
            slices.insert(s("Split Down", "rectangle.split.1x2", "key:shift+cmd+d"), at: 4)
        }
        return HopConfig.Ring(name: name, app: id, slices: slices)
    }
}
