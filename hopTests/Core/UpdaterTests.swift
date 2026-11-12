import Foundation
import Testing
@testable import hop

struct UpdaterTests {
    @Test func updatesConfig() throws {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let off = try d.decode(HopConfig.self, from: Data(#"{ updates: { check: false } }"#.utf8))
        #expect(off.updates.check == false && off.updates.automatic == false)
        let auto = try d.decode(HopConfig.self, from: Data(#"{ updates: { automatic: true } }"#.utf8))
        #expect(auto.updates.check && auto.updates.automatic)
        #expect(HopConfig().updates.check && !HopConfig().updates.automatic)
    }

    @Test func updateChannelFollowsTheRunningVersionUnlessSet() throws {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let auto = HopConfig.Updates()
        #expect(auto.wantsBeta(running: "0.2.0-beta.3"))
        #expect(!auto.wantsBeta(running: "0.2.0"))
        #expect(try d.decode(HopConfig.self, from: Data(#"{ updates: { channel: "beta" } }"#.utf8)).updates.wantsBeta(running: "0.2.0"))
        #expect(try !d.decode(HopConfig.self, from: Data(#"{ updates: { channel: "stable" } }"#.utf8)).updates.wantsBeta(running: "0.2.0-beta.3"))
    }

    /// Builds from source carry no feed or key, so they never check.
    @Test func sourceBuildHasNoUpdater() {
        #expect(!Updater.isConfigured)
    }
}

struct PendingUpdateTests {
    @Test func pawFileLivesInPawsSupportFolder() {
        let url = PendingUpdate.url(bundleID: "com.pseudobun.paw")
        #expect(url.path.hasSuffix("Application Support/com.pseudobun.paw/update.json"))
    }

    @Test func decodesPawsShape() throws {
        let info = try JSONDecoder().decode(PendingUpdate.Info.self, from: Data(#"{"build":"73","version":"0.1.0-beta.5"}"#.utf8))
        #expect(info == .init(version: "0.1.0-beta.5", build: "73"))
    }
}

@MainActor
struct UpdateCommandTests {
    @Test func channelModeWritesTheConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-ch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)
        let mode = UpdateChannelMode(settings: settings)
        let items = try #require(mode.sections(for: "").first?.items)
        #expect(items.map(\.title) == ["Automatic", "Beta", "Stable"])
        #expect(items[0].chip?.text == "Current")
        _ = await items[1].actions[0].perform()
        #expect(settings.data.updates.channel == "beta")
        #expect(mode.sections(for: "").first?.items[1].chip?.text == "Current")
        #expect(mode.sections(for: "sta").first?.items.map(\.title) == ["Stable"])
    }

    @Test func updateCommandsAreInRootSearch() {
        let services = Services(settings: AppSettings(url: URL(fileURLWithPath: "/nonexistent/config.json5")),
                                frecency: FrecencyStore(store: JSONStore(url: FileManager.default.temporaryDirectory.appending(path: "f-\(UUID().uuidString).json"))),
                                apps: AppIndex())
        let ids = Registry.commands(services).map(\.id)
        #expect(ids.contains("hop.update") && ids.contains("hop.updateChannel"))
    }
}
