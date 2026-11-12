import Foundation

nonisolated extension HopConfig {
    nonisolated struct System: PluginConfig {
        static let key = "system"
        var downloadsFolder = "~/Downloads"
    }

    var system: System {
        get { sections[System.self] }
        set { sections[System.self] = newValue }
    }
}

nonisolated extension HopConfig.System {
    private enum Keys: String, CodingKey { case downloadsFolder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        downloadsFolder = try c.value(.downloadsFolder, d.downloadsFolder)
    }
}
