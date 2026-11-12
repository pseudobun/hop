import AppKit
import Foundation
import Testing
@testable import hop

/// Settings → Plugins ordering: by name, last use or install date, either way.
struct PluginSortTests {
    static func info(_ id: String, _ name: String, installed: Double? = nil) -> PluginInfo {
        PluginInfo(id: id, name: name, summary: "", symbol: "star", color: .white, category: .tools,
                   installedAt: installed.map { Date(timeIntervalSince1970: $0) })
    }

    static let plugins = [info("b", "bravo", installed: 20), info("a", "Alpha"), info("c", "Charlie", installed: 10), info("d", "delta")]

    @Test func nameIgnoresCaseBothWays() {
        #expect(PluginSort(key: .name, ascending: true).sorted(Self.plugins).map(\.id) == ["a", "b", "c", "d"])
        #expect(PluginSort(key: .name, ascending: false).sorted(Self.plugins).map(\.id) == ["d", "c", "b", "a"])
    }

    @Test func undatedPluginsStayLastByName() {
        #expect(PluginSort(key: .installed, ascending: false).sorted(Self.plugins).map(\.id) == ["b", "c", "a", "d"])
        #expect(PluginSort(key: .installed, ascending: true).sorted(Self.plugins).map(\.id) == ["c", "b", "a", "d"])
        let used = ["d": Date(timeIntervalSince1970: 5), "a": Date(timeIntervalSince1970: 9)]
        #expect(PluginSort(key: .lastUsed, ascending: false).sorted(Self.plugins) { used[$0] }.map(\.id) == ["a", "d", "b", "c"])
    }

    @Test func usageAndSortSurviveAReload() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<[String: Date]>(url: dir.appending(path: "plugin-usage.json"))
        PluginUsage(store: store).record("notes", now: Date(timeIntervalSince1970: 42))
        #expect(PluginUsage(store: store).lastUsed("notes") == Date(timeIntervalSince1970: 42))

        let defaults = try #require(UserDefaults(suiteName: "hop.tests.\(UUID().uuidString)"))
        #expect(PluginSort.load(defaults) == PluginSort())
        PluginSort(key: .lastUsed, ascending: false).save(defaults)
        #expect(PluginSort.load(defaults) == PluginSort(key: .lastUsed, ascending: false))
    }
}
