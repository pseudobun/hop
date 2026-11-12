import Foundation
import Testing
@testable import hop

struct FileSearchTests {
    @Test func spotlightQueries() {
        #expect(Spotlight.escape(#"a"b*c?\d"#) == #"a\"b\*c\?\\d"#)
        #expect(Spotlight.nameQuery(["just", "file"]) == #"kMDItemFSName == "just*"cdw && kMDItemFSName == "file*"cdw"#)
        #expect(Spotlight.nameQuery(["olymp"], substring: true) == #"kMDItemFSName == "*olymp*"cd"#)
        #expect(Spotlight.contentQuery(["frecency"]) == #"kMDItemTextContent == "frecency*"cdw"#)
    }

    @Test func exclusionsRespectTheScope() {
        let ex = ["node_modules", ".git", "Library"]
        #expect(FilePaths.isExcluded("/Users/u/app/node_modules/x/index.js", patterns: ex, scopes: ["/Users/u"]))
        #expect(FilePaths.isExcluded("/Users/u/Library/Caches/a", patterns: ex, scopes: ["/Users/u"]))
        #expect(!FilePaths.isExcluded("/Users/u/Library/Caches/a", patterns: ex, scopes: ["/Users/u/Library"]))
        #expect(!FilePaths.isExcluded("/Users/u/repos/hop/justfile", patterns: ex, scopes: ["/Users/u"]))
        #expect(!FilePaths.isExcluded("/Users/u/my.gitignore", patterns: ex, scopes: ["/Users/u"]))
    }

    @Test func pathsSplitListAndComplete() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(FilePaths.split("~/Doc")! == (home, "Doc"))
        #expect(FilePaths.split("~/")! == (home, ""))
        #expect(FilePaths.split("/usr/lo")! == ("/usr", "lo"))
        #expect(FilePaths.split("hello") == nil)

        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in ["Projects", "Pictures", "app.app"] { try FileManager.default.createDirectory(at: dir.appending(path: d), withIntermediateDirectories: true) }
        for f in ["notes.txt", ".hidden", "Pro.md"] { try Data().write(to: dir.appending(path: f)) }
        let list = FilePaths.list(dir.path, prefix: "p", showHidden: false)
        #expect(list.map(\.name) == ["Pictures", "Projects", "Pro.md", "app.app"])
        #expect(list.first { $0.name == "app.app" }?.isDirectory == false) // packages open, they don't browse
        #expect(!FilePaths.list(dir.path, prefix: "", showHidden: false).contains { $0.name == ".hidden" })
        #expect(FilePaths.list(dir.path, prefix: ".h", showHidden: false).map(\.name) == [".hidden"])

        let base = dir.path
        #expect(FilePaths.complete(base + "/Proj", hits: FilePaths.list(base, prefix: "Proj", showHidden: false)) == base + "/Projects/")
        #expect(FilePaths.complete(base + "/P", hits: FilePaths.list(base, prefix: "P", showHidden: false)) == nil) // Pictures, Projects, Pro.md
        #expect(FilePaths.complete(base + "/Pr", hits: FilePaths.list(base, prefix: "Pr", showHidden: false)) == base + "/Pro")
    }

    @Test func recencyFavoursFreshShallowFiles() {
        let now = Date()
        let fresh = FileHit(path: "/Users/u/a.txt", modified: now.addingTimeInterval(-3600))
        let old = FileHit(path: "/Users/u/a.txt", modified: now.addingTimeInterval(-86_400 * 90))
        let deep = FileHit(path: "/Users/u/a/b/c/d/e/f/a.txt", modified: now.addingTimeInterval(-3600))
        #expect(FilePaths.recency(fresh, now: now) > FilePaths.recency(old, now: now))
        #expect(FilePaths.recency(fresh, now: now) > FilePaths.recency(deep, now: now))
    }

    @Test func filesConfigDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(c.files == HopConfig.Files())
        #expect(c.files.scopes == ["~"] && c.files.exclude.contains("node_modules"))
    }
}
