import AppKit

/// Flick counts, kept in hop's data folder and nowhere else.
final class RingStats {
    static let shared = RingStats(url: AppPaths.file("ring-stats.json"))

    nonisolated struct Counts: Codable, Equatable, Sendable {
        /// Action key → flicks.
        var actions: [String: Int] = [:]
        var rings: [String: Int] = [:]
        /// "yyyy-MM-dd" → flicks that day.
        var days: [String: Int] = [:]
    }

    private(set) var data = Counts()
    private let url: URL
    private var saveTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        if let raw = try? Foundation.Data(contentsOf: url), let d = try? JSONDecoder().decode(Counts.self, from: raw) { data = d }
    }

    func record(_ action: String, ring: String, on date: Date = Date()) {
        data.actions[action, default: 0] += 1
        if !ring.isEmpty { data.rings[ring, default: 0] += 1 }
        data.days[Self.day(date), default: 0] += 1
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? raw.write(to: url, options: .atomic)
    }

    func reset() {
        data = Counts()
        saveNow()
    }

    var total: Int { data.days.values.reduce(0, +) }

    /// Days in a row with at least one flick, ending today (or yesterday, if today has none yet).
    func streak(today: Date = Date()) -> Int {
        let cal = Calendar.current
        var day = today
        if data.days[Self.day(day)] == nil { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while data.days[Self.day(day)] != nil {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    var bestDay: (String, Int)? { data.days.max { $0.value < $1.value }.map { ($0.key, $0.value) } }

    nonisolated static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Rings in the launcher: every built-in action as a command, each ring by name, statistics.
enum RingCommands {
    nonisolated(unsafe) static weak var controller: RingController?

    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.rings
        guard config.enabled else { return [] }
        var items: [Item] = RingCatalog.all.filter { !$0.isFan }.map { e in
            Item(id: "ring.\(e.id)", title: e.isSwitch ? "Toggle \(e.title)" : e.title, subtitle: e.detail,
                 icon: .tile(e.symbol, color(e.group)), accessory: e.group.rawValue,
                 actions: [Action(title: "Run", symbol: e.symbol) {
                     let ctx = RingContext(app: NSWorkspace.shared.frontmostApplication, point: NSEvent.mouseLocation)
                     services.hideLauncher?()
                     // After the launcher is gone, so the app behind it is in front again.
                     try? await Task.sleep(for: .milliseconds(120))
                     let app = NSWorkspace.shared.frontmostApplication
                     return outcome(await RingRunner.runBuiltin(e.id, RingContext(app: app?.processIdentifier == getpid() ? ctx.app : app,
                                                                                   point: ctx.point)))
                 }])
        }
        let names = (config.rings.map(\.name) + ["Media"]).filter { !$0.isEmpty }
        for name in names {
            items.append(Item(id: "ring.open.\(name.lowercased())", title: "\(name) Ring", subtitle: "Open the ring at the pointer",
                              icon: .tile("circle.circle", Theme.chart2), accessory: "Ring",
                              actions: [Action(title: "Open Ring", symbol: "circle.circle") {
                                  services.hideLauncher?()
                                  try? await Task.sleep(for: .milliseconds(120))
                                  return controller?.open(named: name) == true ? .dismiss : .failWithHUD("No ring \(name)")
                              }]))
        }
        items.append(Item(id: "ring.statistics", title: "Ring Statistics", subtitle: "Your flicks, streak and favourite actions",
                          aliases: ["flicks", "rings"], icon: .tile("chart.bar.fill", Theme.chart2), accessory: "Command",
                          actions: [Action(title: "Show Statistics", symbol: "chart.bar") { .push(RingStatsMode()) }],
                          pushesMode: true))
        return items
    }

    static func color(_ group: RingCatalogEntry.Group) -> NSColor {
        switch group {
        case .system: Theme.info
        case .finder: Theme.chart1
        case .media: Theme.chart5
        case .windows: Theme.chart4
        case .agents: Theme.chart3
        }
    }

    static func outcome(_ o: RingOutcome) -> ActionResult {
        switch o {
        case .done, .fan: .dismiss
        case .hud(let t): .dismissWithHUD(t)
        case .warn(let t): .warnWithHUD(t)
        case .fail(let t): .failWithHUD(t)
        }
    }
}

final class RingStatsMode: Mode {
    let title: String? = "Ring Statistics"
    let placeholder = "Filter actions…"

    func sections(for query: String) -> [ResultSection] {
        let stats = RingStats.shared
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var summary: [Item] = [
            Item(id: "rs.total", title: "\(stats.total)", subtitle: "flicks since you started", icon: .tile("hand.point.up.left.fill", Theme.chart2),
                 actions: [], tracksFrecency: false, monoTitle: true),
            Item(id: "rs.streak", title: "\(stats.streak())", subtitle: "day streak", icon: .tile("flame.fill", Theme.warn),
                 actions: [], tracksFrecency: false, monoTitle: true),
        ]
        if let best = stats.bestDay {
            summary.append(Item(id: "rs.best", title: "\(best.1)", subtitle: "on your best day, \(best.0)", icon: .tile("trophy.fill", Theme.good),
                                actions: [], tracksFrecency: false, monoTitle: true))
        }
        let top = stats.data.actions.sorted { $0.value > $1.value }.filter { q.isEmpty || $0.key.contains(q) }.prefix(30).map { key, n in
            let entry = RingCatalog.entry(key)
            return Item(id: "rs.a.\(key)", title: entry?.title ?? key, icon: .tile(entry?.symbol ?? "circle", Theme.chart1),
                        accessory: "\(n)×", actions: [], tracksFrecency: false)
        }
        let rings = stats.data.rings.sorted { $0.value > $1.value }.prefix(10).map { name, n in
            Item(id: "rs.r.\(name)", title: name, icon: .tile("circle.circle", Theme.chart4), accessory: "\(n)×", actions: [], tracksFrecency: false)
        }
        let reset = Item(id: "rs.reset", title: "Reset Statistics", subtitle: "Delete every flick recorded on this Mac",
                         icon: .tile("trash", Theme.destructive),
                         actions: [Action(title: "Reset", style: .destructive) {
                             RingStats.shared.reset()
                             return .reload
                         }], tracksFrecency: false)
        return [ResultSection(title: nil, items: q.isEmpty ? summary : []),
                ResultSection(title: "Favourite actions", items: Array(top)),
                ResultSection(title: "Rings", items: q.isEmpty ? Array(rings) : []),
                ResultSection(title: nil, items: q.isEmpty ? [reset] : [])].filter { !$0.items.isEmpty }
    }
}
