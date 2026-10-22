import Foundation

/// Raycast 2.8.2 frecency, re-stated from disassembly of its Rust data addon
/// (raycast-re spec-search.md §7). A single "anchor" timestamp encodes the score,
/// so ordering by anchor equals ordering by current score.
nonisolated enum Frecency {
    static let lambdaPerDay = 0.06878274660137416
    static let secondsPerDay = 86_400.0
    static let exponentClamp = 709.782712893384
    static let visitPoints = 100.0

    /// Score of `anchor` at time `t` (seconds since 1970). Floored at 1.
    static func score(anchor: Double, at t: Double) -> Double {
        max(1, exp(min(lambdaPerDay * (anchor - t) / secondsPerDay, exponentClamp)))
    }

    /// New anchor after a visit at `t`.
    static func visit(anchor: Double?, at t: Double) -> Double {
        let a = anchor.map { max($0, t) } ?? t
        let s = max(1, exp(min(lambdaPerDay * (a - t) / secondsPerDay, exponentClamp)))
        return t + secondsPerDay * log(min(s + visitPoints, .greatestFiniteMagnitude)) / lambdaPerDay
    }
}

/// Persists one anchor per item id in `frecency.json`.
final class FrecencyStore {
    struct Entry: Codable { var anchor: Double; var openedAt: Date }

    private let store: JSONStore<[String: Entry]>
    private var entries: [String: Entry]

    init(store: JSONStore<[String: Entry]>) {
        self.store = store
        entries = store.load() ?? [:]
    }

    func score(_ id: String, now: Date = Date()) -> Double {
        guard let e = entries[id] else { return 1 }
        return Frecency.score(anchor: e.anchor, at: now.timeIntervalSince1970)
    }

    func recordVisit(_ id: String, now: Date = Date()) {
        let anchor = Frecency.visit(anchor: entries[id]?.anchor, at: now.timeIntervalSince1970)
        entries[id] = Entry(anchor: anchor, openedAt: now)
        store.save(entries)
    }

    func reset(_ id: String) {
        entries[id] = nil
        store.save(entries)
    }
}
