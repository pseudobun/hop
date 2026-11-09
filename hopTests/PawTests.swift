import Foundation
import Testing
@testable import hop

struct PawTests {
    @Test func parsesSetupsConnectedFirst() {
        let json = """
        [ { "name": "home", "displays": ["builtin", "DELL", "Gigabyte"], "matches": false, "workspaces": ["1", "8", "9"] },
          { "name": "laptop-only", "displays": ["builtin"], "matches": true, "workspaces": ["1", "2"] } ]
        """
        let list = Paw.parse(json)
        #expect(list.map(\.name) == ["laptop-only", "home"])
        #expect(list[0].label == "Laptop Only" && list[0].matches)
        #expect(list[1].displays == ["builtin", "DELL", "Gigabyte"] && list[1].workspaces.count == 3)
    }

    @Test func badOutputIsNoSetups() {
        #expect(Paw.parse("paw is not running").isEmpty)
    }
}
