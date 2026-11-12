import Foundation

/// A plugin's section of `config.json5` (`notes: { … }`). Missing keys keep the defaults of
/// `init()`; the type's property names are the JSON keys (Settings and the unknown-key check
/// read them off a default value).
nonisolated protocol PluginConfig: Decodable, Equatable, Sendable {
    /// The section's top-level key in `config.json5`.
    static var key: String { get }
    /// Elements of lists that are empty by default, so the unknown-key check knows their keys:
    /// `["databases": Database()]` (paths relative to the section).
    static var samples: [String: Any] { get }
    /// What Settings and the unknown-key check read keys from: the section itself, or e.g. the
    /// list it wraps.
    var reflected: Any { get }
    init()
}

nonisolated extension PluginConfig {
    static var samples: [String: Any] { [:] }
    var reflected: Any { self }

    fileprivate func isEqual(_ other: any PluginConfig) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }

    fileprivate static func decode<K: CodingKey>(from container: KeyedDecodingContainer<K>, key: K) throws -> any PluginConfig {
        try container.decodeIfPresent(Self.self, forKey: key) ?? Self()
    }
}

/// The plugin sections of a loaded config, by key. A section that is missing (or a plugin
/// that is not compiled in) reads as its defaults.
nonisolated struct PluginConfigs: Equatable, Sendable {
    private var values: [String: any PluginConfig] = [:]

    subscript<C: PluginConfig>(_ type: C.Type) -> C {
        get { values[C.key] as? C ?? C() }
        set { values[C.key] = newValue }
    }

    /// The decoded section at `key`, or its defaults when the key belongs to a known plugin.
    func section(_ key: String) -> (any PluginConfig)? {
        values[key] ?? PluginConfigs.types.first { $0.key == key }.map { $0.init() }
    }

    static func == (a: PluginConfigs, b: PluginConfigs) -> Bool {
        let keys = Set(a.values.keys).union(b.values.keys)
        return keys.allSatisfy { key in
            switch (a.section(key), b.section(key)) {
            case let (x?, y?): x.isEqual(y)
            case (nil, nil): true
            default: false
            }
        }
    }

    /// Section types of the plugins compiled into hop (`BuiltinPlugins.configTypes`).
    static var types: [any PluginConfig.Type] { BuiltinPlugins.configTypes }

    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init() {}

    /// Decodes every known plugin section from the top-level object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for type in Self.types {
            values[type.key] = try type.decode(from: c, key: AnyKey(stringValue: type.key))
        }
    }
}
