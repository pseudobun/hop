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
