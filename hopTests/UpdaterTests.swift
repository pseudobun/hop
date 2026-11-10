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
