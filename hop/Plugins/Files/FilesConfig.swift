import Foundation

nonisolated extension HopConfig {
    nonisolated struct Files: PluginConfig {
        static let key = "files"
        var enabled = true
        /// Folders Spotlight searches.
        var scopes = ["~"]
        /// Path components that hide a result.
        var exclude = ["node_modules", ".git", "Library", "DerivedData", ".Trash", ".cache", "Caches"]
        /// Also list files whose text matches (Spotlight's content index).
        var contentSearch = true
        var maxResults = 60
        /// Show dotfiles when browsing a path.
        var showHidden = false
    }

    var files: Files {
        get { sections[Files.self] }
        set { sections[Files.self] = newValue }
    }
}

nonisolated extension HopConfig.Files {
    private enum Keys: String, CodingKey { case enabled, scopes, exclude, contentSearch, maxResults, showHidden }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        scopes = try c.value(.scopes, d.scopes)
        exclude = try c.value(.exclude, d.exclude)
        contentSearch = try c.value(.contentSearch, d.contentSearch)
        maxResults = try c.value(.maxResults, d.maxResults)
        showHidden = try c.value(.showHidden, d.showHidden)
    }
}
