import Foundation
import Testing
@testable import hop

struct PluginLiveReloadTests {
    /// Disabling KeePassXC or taking a database out of the config locks what was unlocked.
    @Test func keePassLocksWhatTheConfigNoLongerAllows() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-kp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.kdbx"), b = dir.appending(path: "b.kdbx")
        for db in [a, b] { try Data("not really".utf8).write(to: db) }
        let url = dir.appending(path: "config.json5")
        func write(_ paths: [URL], enabled: Bool = true) throws {
            let dbs = paths.map { "{ path: \"\($0.path)\", password: \"prompt\" }" }.joined(separator: ", ")
            try "{ keepass: { enabled: \(enabled), cli: \"\(KeePassCLITests.fake)\", databases: [\(dbs)] } }"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try write([a, b])
        let settings = AppSettings(url: url)
        let manager = KeePassManager(settings: settings)
        manager.apply(settings.data.keepass, enabled: true)
        try await manager.session(a.path).unlock(password: "secret")
        try await manager.session(b.path).unlock(password: "secret")
        #expect(manager.unlockedPaths == [a.path, b.path])

        try write([a])
        settings.load()
        manager.apply(settings.data.keepass, enabled: true)
        #expect(manager.unlockedPaths == [a.path])

        try write([a], enabled: false)
        settings.load()
        manager.apply(settings.data.keepass, enabled: false)
        #expect(manager.unlockedPaths.isEmpty)
    }

    /// Emoji suggestions and the failure HUD belong to one model.
    @Test func emojiAIStartsOverForAnotherModel() {
        EmojiMode.useModel("model-a", reasoning: "none")
        EmojiMode.debugSeedAI("ko deploy faila", [1, 2], warned: true)
        EmojiMode.useModel("model-a", reasoning: "none")
        #expect(EmojiMode.aiCache[EmojiMode.aiKey("ko deploy faila")] == [1, 2] && EmojiMode.warned)
        EmojiMode.useModel("model-b", reasoning: "none")
        #expect(EmojiMode.aiCache.isEmpty && !EmojiMode.warned)
        EmojiMode.debugSeedAI("x", [3], warned: true)
        EmojiMode.useModel("model-b", reasoning: "low")
        #expect(EmojiMode.aiCache.isEmpty && !EmojiMode.warned)
    }

    /// Saves that leave a plugin alone keep its background timers; its own settings or switch
    /// start them over.
    @Test func externalPluginKeepsTimersAcrossUnrelatedSaves() throws {
        let m = try PluginManifest.decode(Data(PluginManifestTests.manifest.utf8))
        let plugin = ExternalPlugin(manifest: m, directory: URL(fileURLWithPath: "/tmp"), record: nil)
        defer { plugin.stop() }
        var config = HopConfig()
        plugin.apply(config, previous: nil, enabled: true)
        let first = try #require(plugin.timers.first)
        #expect(plugin.timers.count == 1 && first.isValid)

        var other = config
        other.general.keepQueryFor = 3
        plugin.apply(other, previous: config, enabled: true)
        #expect(plugin.timers.first === first && first.isValid)

        config = other
        other.plugins.settings[m.id] = .object(["max": .number(9)])
        plugin.apply(other, previous: config, enabled: true)
        #expect(plugin.timers.count == 1 && plugin.timers.first !== first && !first.isValid)

        plugin.apply(other, previous: other, enabled: false)
        #expect(plugin.timers.isEmpty)
        plugin.apply(other, previous: other, enabled: true)
        #expect(plugin.timers.count == 1)
    }
}
