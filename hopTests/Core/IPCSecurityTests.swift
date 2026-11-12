import Foundation
import Testing
@testable import hop

struct IPCSecurityTests {
    @Test func hudTextIsOnePlainLine() {
        #expect(HUD.sanitized("a\nb\tc\u{1B}[31m") == "a b c[31m")
        #expect(HUD.sanitized("safe\u{202E}txt.exe") == "safetxt.exe")
        #expect(HUD.sanitized(String(repeating: "x", count: 500)).count == 160)
    }

    @Test func jsonStoreIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<[String]>(url: dir.appending(path: "x.json"))
        store.save(["a"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "x.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func socketPathFits() {
        #expect(HopIPC.address(HopIPC.socketURL.path) != nil)
        #expect(HopIPC.address(String(repeating: "x", count: 200)) == nil)
    }
}
