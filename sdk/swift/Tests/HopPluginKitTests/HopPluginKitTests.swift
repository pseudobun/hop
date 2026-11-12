import Foundation
import Testing
@testable import HopPluginKit

@Test func viewEncodesLikeHopReadsIt() throws {
    let view = View.list().title("T").item(Item("a", "A").icon(.symbol("star")).action(.copy("Copy", "x").shortcut("cmd+c")))
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Response.view(view)))
    #expect(json["view"]?["type"]?.string == "list")
    #expect(json["view"]?["filtering"]?.string == "hop")
    guard case .array(let sections)? = json["view"]?["sections"], case .array(let items)? = sections.first?["items"],
          case .array(let actions)? = items.first?["actions"] else { Issue.record("shape"); return }
    #expect(actions.first?["type"]?.string == "copy")
    #expect(actions.first?["shortcut"]?.string == "cmd+c")
}

@Test func pushedViewsNest() throws {
    let inner = View.list().item(Item("b", "B"))
    let action = Action.push("More", inner)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(action))
    #expect(json["type"]?.string == "push")
    #expect(json["view"]?["type"]?.string == "list")
}

@Test func cliOutputAndConfirmEncode() throws {
    let out = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(CLIOutput.print("hi\n")))
    #expect(out["stdout"]?.string == "hi\n" && out["exitCode"]?.number == 0)
    let a = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Action.callback("Delete", id: "d").destructive().confirm("Sure?")))
    #expect(a["confirm"]?["message"]?.string == "Sure?")
    let v = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(View.list().submitting().secure()))
    #expect(v["submit"]?.bool == true && v["secureInput"]?.bool == true)
}
