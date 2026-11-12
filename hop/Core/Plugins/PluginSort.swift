import Foundation

/// How the Plugins page orders its list. A view preference, so it is kept per Mac in
/// UserDefaults rather than in config.json5.
struct PluginSort: Equatable {
    enum Key: String, CaseIterable {
        case name, lastUsed, installed

        var title: String {
            switch self {
            case .name: "Name"
            case .lastUsed: "Last Used"
            case .installed: "Installed"
            }
        }
    }

    var key: Key = .name
    /// Name: A→Z. Dates: oldest first. Plugins without a date (never used; built in, for
    /// Installed) always come last, by name.
    var ascending = true

    private static let keyDefault = "settings.pluginSort.key"
    private static let ascendingDefault = "settings.pluginSort.ascending"

    static func load(_ defaults: UserDefaults = .standard) -> PluginSort {
        var sort = PluginSort()
        if let raw = defaults.string(forKey: keyDefault), let key = Key(rawValue: raw) { sort.key = key }
        if defaults.object(forKey: ascendingDefault) != nil { sort.ascending = defaults.bool(forKey: ascendingDefault) }
        return sort
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(key.rawValue, forKey: Self.keyDefault)
        defaults.set(ascending, forKey: Self.ascendingDefault)
    }

    /// `lastUsed` answers when a plugin's command last ran.
    func sorted(_ plugins: [PluginInfo], lastUsed: (String) -> Date? = { _ in nil }) -> [PluginInfo] {
        let byName = { (a: PluginInfo, b: PluginInfo) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        if key == .name { return plugins.sorted { ascending ? byName($0, $1) : byName($1, $0) } }
        let dates = Dictionary(plugins.map { ($0.id, key == .lastUsed ? lastUsed($0.id) : $0.installedAt) }) { a, _ in a }
        let date = { (p: PluginInfo) in dates[p.id] ?? nil }
        return plugins.sorted { a, b in
            switch (date(a), date(b)) {
            case let (da?, db?) where da != db: ascending ? da < db : da > db
            case (_?, nil): true
            case (nil, _?): false
            default: byName(a, b)
            }
        }
    }
}

/// When each plugin's commands last ran, in `plugin-usage.json`, for sorting by Last Used.
final class PluginUsage {
    private let store: JSONStore<[String: Date]>
    private var last: [String: Date]

    init(store: JSONStore<[String: Date]>) {
        self.store = store
        last = store.load() ?? [:]
    }

    func lastUsed(_ id: String) -> Date? { last[id] }

    func record(_ id: String, now: Date = Date()) {
        last[id] = now
        store.save(last)
    }
}
