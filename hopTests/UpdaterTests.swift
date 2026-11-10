import Foundation
import Testing
@testable import hop

struct UpdaterTests {
    @Test func versionOrder() {
        let ordered = ["0.1.0-alpha", "0.1.0-beta.1", "0.1.0-beta.2", "0.1.0-beta.10", "0.1.0-rc.1", "0.1.0", "0.1.1", "0.2.0-beta.1", "0.2.0", "1.0.0"]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(ReleaseVersion.isNewer(b, than: a), "\(b) > \(a)")
            #expect(!ReleaseVersion.isNewer(a, than: b), "\(a) < \(b)")
        }
        #expect(ReleaseVersion.compare("v0.1.0-beta.1", "0.1.0-beta.1") == .orderedSame)
        #expect(ReleaseVersion.compare("0.1", "0.1.0") == .orderedSame)
        #expect(ReleaseVersion.isPrerelease("v0.1.0-beta.3") && !ReleaseVersion.isPrerelease("0.1.0"))
    }

    @Test func picksNewestPublishedRelease() {
        func r(_ tag: String, draft: Bool = false, pre: Bool = false) -> ReleaseFeed.Release {
            .init(tag_name: tag, html_url: "https://github.com/pseudobun/hop/releases/tag/\(tag)", draft: draft, prerelease: pre)
        }
        let releases = [r("v0.1.0-beta.2", pre: true), r("v0.3.0", draft: true), r("v0.1.0-beta.10", pre: true), r("v0.0.9")]
        #expect(ReleaseFeed.pick(releases, includePrereleases: true)?.version == "0.1.0-beta.10")
        #expect(ReleaseFeed.pick(releases, includePrereleases: false)?.version == "0.0.9")
        #expect(ReleaseFeed.pick([], includePrereleases: true) == nil)
    }

    @Test func updatesConfig() throws {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let off = try d.decode(HopConfig.self, from: Data(#"{ updates: { check: false } }"#.utf8))
        #expect(off.updates.check == false)
        #expect(HopConfig().updates.check)
    }
}
