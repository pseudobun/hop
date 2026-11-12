import Foundation

/// The plugins compiled into hop: the one list that registers them.
nonisolated enum BuiltinPlugins {
    /// In start order: Snippets uses Clipboard's store.
    @MainActor static let types: [any BuiltinPlugin.Type] = [
        HyperKeyPlugin.self, ClipboardPlugin.self, SnippetsPlugin.self,
        NotesPlugin.self, FilesPlugin.self, ShelfPlugin.self, CalculatorPlugin.self,
        EmojiPlugin.self, TranslatePlugin.self, ScreenTextPlugin.self,
        WireGuardPlugin.self, KeePassPlugin.self, CalendarPlugin.self, MessagesPlugin.self,
        BookmarksPlugin.self, PawPlugin.self, SystemPlugin.self,
    ]

    @MainActor static func makeAll() -> [any HopPlugin] { types.map { $0.init() } }

    /// Config sections, so `config.json5` decodes them (`PluginConfigs`).
    static let configTypes: [any PluginConfig.Type] = [
        HopConfig.HyperKey.self, HopConfig.Snippets.self,
        HopConfig.Clipboard.self, HopConfig.Notes.self, HopConfig.Files.self, HopConfig.Shelf.self,
        HopConfig.CalculatorSettings.self, HopConfig.System.self,
        HopConfig.Emoji.self, HopConfig.Translate.self, HopConfig.OCR.self,
        HopConfig.WireGuard.self, HopConfig.KeePass.self, HopConfig.CalendarSettings.self,
        HopConfig.Messages.self, HopConfig.Bookmarks.self,
    ]

    /// Whether a plugin that is on needs Accessibility (key taps, pasting, typing).
    static func needsAccessibility(_ config: HopConfig) -> Bool {
        config.hyperKey.enabled || config.keepass.enabled || config.clipboard.enabled
            || (config.snippets.enabled && config.snippets.expand)
    }
}
