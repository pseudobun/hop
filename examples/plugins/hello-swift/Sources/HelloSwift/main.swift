// hop's example plugin in Swift: a searchable list, a pushed view, a callback.

import Foundation
import HopPluginKit

struct HelloSwift: HopPlugin {
    var name = "friend"

    mutating func initialize(_ cx: inout Context) throws {
        name = cx.preferences["name"]?.string ?? "friend"
    }

    mutating func run(_ cx: inout Context, command: String, query: String?) throws -> Response {
        switch command {
        case "fruit":
            let fruit = [("apple", "🍎"), ("banana", "🍌"), ("cherries", "🍒"), ("grapes", "🍇"), ("kiwi", "🥝"), ("lemon", "🍋")]
            return .view(View.list().placeholder("Fruit for \(name)…").emptyText("No such fruit").items(fruit.map { word, emoji in
                Item(word, word.capitalized)
                    .icon(.emoji(emoji))
                    .action(.paste("Paste Emoji", emoji))
                    .action(.copy("Copy Name", word).shortcut("cmd+c"))
                    .action(.push("Show Letters", View.list().title(word.capitalized).items(word.map { letter in
                        Item(String(letter), String(letter).uppercased()).action(.copy("Copy Letter", String(letter)))
                    })).shortcut("cmd+l"))
                    .action(.callback("Rate It", id: "rate", payload: .string(word)).shortcut("cmd+r"))
            }))
        default:
            throw PluginError("unknown command \(command)")
        }
    }

    mutating func action(_ cx: inout Context, command: String, id: String, payload: JSONValue?) throws -> Response {
        guard id == "rate", let word = payload?.string else { throw PluginError("unknown action \(id)") }
        return .hud("\(word.capitalized): \(word.count % 5 + 1)/5 for \(name)")
    }
}

serve(HelloSwift())
