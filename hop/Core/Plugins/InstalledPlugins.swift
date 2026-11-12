import Foundation

/// Plugins installed from GitHub (filled in by the external plugin runtime).
enum InstalledPlugins {
    static func load() -> [any HopPlugin] { [] }
}
