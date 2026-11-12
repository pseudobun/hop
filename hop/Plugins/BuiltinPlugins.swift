import Foundation

/// The plugins compiled into hop: the one list that registers them.
nonisolated enum BuiltinPlugins {
    /// Config sections, so `config.json5` decodes them (`PluginConfigs`).
    static let configTypes: [any PluginConfig.Type] = [
        HopConfig.HyperKey.self, HopConfig.Snippets.self,
        HopConfig.Clipboard.self, HopConfig.Notes.self, HopConfig.Files.self, HopConfig.Shelf.self,
        HopConfig.CalculatorSettings.self, HopConfig.System.self,
        HopConfig.Emoji.self, HopConfig.Translate.self, HopConfig.OCR.self,
        HopConfig.WireGuard.self, HopConfig.KeePass.self, HopConfig.CalendarSettings.self,
        HopConfig.Messages.self, HopConfig.Bookmarks.self,
    ]
}
