import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Snippets plugin.
extension SnippetsPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["snippets"], usage: [
                "snippets [list] [--json]            Snippets from snippets.json5 with their keywords",
                "snippets expand <name|keyword> [--arg=value…]   Print a snippet with its placeholders filled in",
                "snippets add <name> [text] [--keyword=;k]       Append a snippet (text or stdin)",
                "snippets template                   Print the default snippets.json5",
            ], run: CLI.snippets),
        ]
    }
}

extension CLI {
    static func snippets(_ a: Args) async -> Int32 {
        if a.positional.first == "template" {
            print(SnippetsFile.template, terminator: "")
            return 0
        }
        let config = AppSettings().data
        let file = SnippetsFile(url: URL(fileURLWithPath: config.snippets.file.expandingTilde))
        file.load()
        if let error = file.error { return Output.fail(error) }
        var words = a.positional
        let sub = ["list", "expand", "add"].contains(words.first ?? "") ? words.removeFirst() : "list"
        switch sub {
        case "expand":
            let key = words.joined(separator: " ")
            guard let s = file.snippets.first(where: { $0.keyword == key }) ?? file.snippets.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })
            else { return Output.fail("no snippet named or keyed \(key)") }
            let args = a.options.filter { $0.key != "keyword" }
            var values: [String] = []
            for (i, arg) in s.arguments.enumerated() {
                values.append(arg.name.flatMap { args[$0] } ?? args["\(i + 1)"] ?? "")
            }
            var ctx = Placeholders.Context()
            ctx.snippets = file.snippets
            ctx.arguments = values
            ctx.calculate = { (try? Calculator.evaluate($0)).map { Calculator.format($0, locale: Locale(identifier: "en_US_POSIX")) } }
            let history = ClipboardStore()
            if config.clipboard.cliAccess { history.load() }
            ctx.clipboard = { offset in
                if offset < history.items.count { return history.items[offset].text }
                return offset == 0 ? NSPasteboard.general.string(forType: .string) ?? "" : ""
            }
            do {
                print(try Placeholders.expand(s.text, name: s.name, context: ctx).text, terminator: "")
                return 0
            } catch Placeholders.ExpansionError.placeholder(let m) {
                return Output.fail(m)
            } catch {
                return Output.fail(error.localizedDescription)
            }
        case "add":
            guard let name = words.first, !name.isEmpty else { return Output.fail("usage: hop snippets add <name> [text] [--keyword=;k]") }
            let text = words.count > 1 ? words.dropFirst().joined(separator: " ") : stdinText() ?? ""
            guard !text.isEmpty else { return Output.fail("no text: pass it or pipe it in") }
            guard file.append(Snippet(name: name, keyword: a.option("keyword"), text: text)) else {
                return Output.fail("could not write \(file.url.path)")
            }
            print("added \(name) to \(file.url.path)")
            return 0
        default:
            if a.json {
                Output.json(file.snippets.map { ["name": $0.name, "keyword": $0.keyword ?? "", "text": $0.text] })
            } else {
                for s in file.snippets { print("\(s.name)\t\(s.keyword ?? "-")\t\(s.text.split(whereSeparator: \.isNewline).first ?? "")") }
            }
            return 0
        }
    }
}
