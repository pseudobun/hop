// Write hop plugins in Swift. A plugin is a program hop starts on demand: it reads JSON-RPC
// requests from stdin, one per line, and answers on stdout. hop draws everything; a plugin
// only describes lists, grids and actions with these types. See docs/plugins.md in hop.
//
//     struct Hello: HopPlugin {
//         mutating func run(_ cx: inout Context, command: String, query: String?) throws -> Response {
//             .view(View.list().item(Item("hi", "Hello").action(.copy("Copy", "Hello"))))
//         }
//     }
//     HopPluginKit.serve(Hello())

import Foundation

public let protocolVersion = 1

// MARK: - JSON

/// Any JSON value: payloads and preferences.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
}

// MARK: - Views

public struct View: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case list, grid }
    /// Who ranks items as the user types: hop (default, fast) or the plugin (`query`).
    public enum Filtering: String, Codable, Sendable { case hop, plugin }

    public var type: Kind = .list
    public var title: String?
    public var placeholder: String?
    public var filtering: Filtering = .hop
    public var columns: Int?
    public var sections: [Section] = []
    public var emptyText: String?
    public var loading: Bool?
    /// ↵ with no row selected sends the typed text to `submit(…)`.
    public var submit: Bool?
    /// The search field hides what is typed.
    public var secureInput: Bool?

    public init() {}

    public static func list() -> View { View() }

    /// Large glyphs (emoji icons) in `columns` columns.
    public static func grid(columns: Int = 8) -> View {
        var v = View()
        v.type = .grid
        v.columns = columns
        return v
    }

    public func title(_ text: String) -> View { var v = self; v.title = text; return v }
    public func placeholder(_ text: String) -> View { var v = self; v.placeholder = text; return v }
    public func filtering(_ f: Filtering) -> View { var v = self; v.filtering = f; return v }
    public func emptyText(_ text: String) -> View { var v = self; v.emptyText = text; return v }
    public func loading(_ on: Bool) -> View { var v = self; v.loading = on; return v }
    public func section(_ s: Section) -> View { var v = self; v.sections.append(s); return v }
    /// ↵ with nothing selected calls `submit(…)` (a text prompt).
    public func submitting() -> View { var v = self; v.submit = true; return v }
    /// Hide what is typed (a password prompt).
    public func secure() -> View { var v = self; v.secureInput = true; return v }

    /// Adds an item to the last untitled section.
    public func item(_ item: Item) -> View {
        var v = self
        if let last = v.sections.indices.last, v.sections[last].title == nil {
            v.sections[last].items.append(item)
        } else {
            v.sections.append(Section(nil, [item]))
        }
        return v
    }

    public func items(_ items: [Item]) -> View { items.reduce(self) { $0.item($1) } }
}

public struct Section: Codable, Equatable, Sendable {
    public var title: String?
    public var items: [Item]

    public init(_ title: String?, _ items: [Item] = []) {
        self.title = title
        self.items = items
    }
}

/// A row or grid cell; `actions[0]` runs on ↵, the rest are in the action panel (⌘K).
public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon?
    public var accessory: String?
    public var keywords: [String]?
    public var chip: Chip?
    public var actions: [Action] = []

    public init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }

    public func subtitle(_ text: String) -> Item { var i = self; i.subtitle = text; return i }
    public func icon(_ icon: Icon) -> Item { var i = self; i.icon = icon; return i }
    public func accessory(_ text: String) -> Item { var i = self; i.accessory = text; return i }
    public func keywords(_ words: [String]) -> Item { var i = self; i.keywords = words; return i }
    public func action(_ action: Action) -> Item { var i = self; i.actions.append(action); return i }
    /// A tinted status chip; `tone` is neutral, good, warn, bad or info.
    public func chip(_ text: String, tone: String = "neutral") -> Item { var i = self; i.chip = Chip(text: text, tone: tone); return i }
}

public struct Chip: Codable, Equatable, Sendable {
    public var text: String
    public var tone: String?
}

/// Asks before an action runs.
public struct Confirm: Codable, Equatable, Sendable {
    public var title: String?
    public var message: String
    public var button: String?
}

public struct Icon: Codable, Equatable, Sendable {
    public var symbol: String?
    public var color: String?
    public var emoji: String?
    public var file: String?

    public init() {}

    /// An SF Symbol on a tile, in `color` ("#rrggbb") or the plugin's colour.
    public static func symbol(_ name: String, color: String? = nil) -> Icon { var i = Icon(); i.symbol = name; i.color = color; return i }
    public static func emoji(_ e: String) -> Icon { var i = Icon(); i.emoji = e; return i }
    /// An image file, absolute or relative to the plugin folder.
    public static func file(_ path: String) -> Icon { var i = Icon(); i.file = path; return i }
}

/// What an item does. hop runs everything but `callback`, which comes back to `action(…)`.
public struct Action: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case copy, paste, open, openFile, reveal, push, callback }

    public var title: String
    public var type: Kind
    public var value: String?
    public var url: String?
    public var path: String?
    public var view: Box<View>?
    public var id: String?
    public var payload: JSONValue?
    public var shortcut: String?
    public var destructive: Bool?
    public var confirm: Confirm?

    init(_ title: String, _ type: Kind) {
        self.title = title
        self.type = type
    }

    public static func copy(_ title: String, _ value: String) -> Action { var a = Action(title, .copy); a.value = value; return a }
    public static func paste(_ title: String, _ value: String) -> Action { var a = Action(title, .paste); a.value = value; return a }
    public static func open(_ title: String, url: String) -> Action { var a = Action(title, .open); a.url = url; return a }
    public static func openFile(_ title: String, path: String) -> Action { var a = Action(title, .openFile); a.path = path; return a }
    public static func reveal(_ title: String, path: String) -> Action { var a = Action(title, .reveal); a.path = path; return a }
    public static func push(_ title: String, _ view: View) -> Action { var a = Action(title, .push); a.view = Box(view); return a }
    public static func callback(_ title: String, id: String, payload: JSONValue = .null) -> Action {
        var a = Action(title, .callback)
        a.id = id
        a.payload = payload
        return a
    }

    /// "cmd+c", "cmd+shift+return".
    public func shortcut(_ keys: String) -> Action { var a = self; a.shortcut = keys; return a }
    public func destructive(_ on: Bool = true) -> Action { var a = self; a.destructive = on; return a }
    /// A screen with `message` and a confirm row before the action runs.
    public func confirm(_ message: String, title: String? = nil, button: String? = nil) -> Action {
        var a = self
        a.confirm = Confirm(title: title, message: message, button: button)
        return a
    }
}

/// Lets a view hold actions that hold views.
public final class Box<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
    public required init(from decoder: Decoder) throws { value = try T(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    public static func == (a: Box, b: Box) -> Bool { a.value == b.value }
}

// MARK: - Responses

public struct HUD: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case info, success, warn, fail }
    public var text: String
    public var style: Style?
}

/// What hop does after a request: show or push a view, pop, flash a HUD, hide.
public struct Response: Codable, Equatable, Sendable {
    public var view: View?
    public var push: View?
    public var pop: Bool?
    public var hud: HUD?
    public var dismiss: Bool?

    public init() {}

    public static let none = Response()
    public static func view(_ v: View) -> Response { var r = Response(); r.view = v; return r }
    public static func push(_ v: View) -> Response { var r = Response(); r.push = v; return r }
    public static var pop: Response { var r = Response(); r.pop = true; return r }
    public static func hud(_ text: String, style: HUD.Style? = nil) -> Response { var r = Response(); r.hud = HUD(text: text, style: style); return r }
    public static func fail(_ text: String) -> Response { hud(text, style: .fail) }
    /// Also hide the launcher.
    public func dismissing() -> Response { var r = self; r.dismiss = true; return r }
}

// MARK: - The plugin

/// What hop sends when it starts the program.
public struct Initialize: Codable, Sendable {
    public var protocolVersion = 1
    public var hopVersion = ""
    public var pluginID = ""
    /// Settings by preference id, defaults and Keychain secrets filled in.
    public var preferences: [String: JSONValue] = [:]
    /// A folder to keep files in.
    public var dataDir = ""
    /// "dark" or "light".
    public var appearance = "dark"

    public init() {}
}

/// Talks to hop outside a reply: update the open view, flash a HUD.
public struct Context {
    public internal(set) var initialize = Initialize()
    public var preferences: [String: JSONValue] { initialize.preferences }

    /// Replaces the open view of `command` (for work that finishes after the reply).
    public func render(_ command: String, _ view: View) {
        var params = (try? JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(Response.view(view)))) ?? [:]
        params["command"] = .string(command)
        send(["jsonrpc": .string("2.0"), "method": .string("render"), "params": .object(params)])
    }

    public func hud(_ text: String) {
        send(["jsonrpc": .string("2.0"), "method": .string("hud"), "params": .object(["text": .string(text)])])
    }

    public func loading(_ on: Bool) {
        send(["jsonrpc": .string("2.0"), "method": .string("loading"), "params": .object(["loading": .bool(on)])])
    }

    /// Root-search commands and Upcoming items beyond plugin.json5's (send again to change).
    public func rootItems(_ items: [Item], upcoming: [Item] = []) {
        let params = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(RootItems(items: items, upcoming: upcoming)))) ?? .null
        send(["jsonrpc": .string("2.0"), "method": .string("rootItems"), "params": params])
    }
}

struct RootItems: Codable { var items: [Item]; var upcoming: [Item] }

/// An inline answer in root search: a titled section of items.
public struct Answer: Codable, Equatable, Sendable {
    public var title: String?
    public var items: [Item]
    public init(title: String? = nil, items: [Item]) {
        self.title = title
        self.items = items
    }
}

/// What `hop <name> …` prints and exits with.
public struct CLIOutput: Codable, Equatable, Sendable {
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int
    public init(stdout: String? = nil, stderr: String? = nil, exitCode: Int = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
    public static func print(_ text: String) -> CLIOutput { CLIOutput(stdout: text) }
    public static func fail(_ text: String, code: Int = 1) -> CLIOutput { CLIOutput(stderr: text, exitCode: code) }
}

/// Implement what you need; `run` is the only required method.
public protocol HopPlugin {
    mutating func initialize(_ cx: inout Context) throws
    /// A command from plugin.json5 was opened or run; `query` is the text after its prefix.
    mutating func run(_ cx: inout Context, command: String, query: String?) throws -> Response
    /// The search text changed in a view with `.filtering(.plugin)`.
    mutating func query(_ cx: inout Context, command: String, text: String) throws -> Response
    /// A `callback` action ran. Root items use command "root", answers "answer", app actions "app".
    mutating func action(_ cx: inout Context, command: String, id: String, payload: JSONValue?) throws -> Response
    /// ↵ in a view made with `.submitting()`.
    mutating func submit(_ cx: inout Context, command: String, text: String) throws -> Response
    /// A root-search query (with `answers: true` in plugin.json5); nil shows nothing.
    mutating func answer(_ cx: inout Context, text: String) throws -> Answer?
    /// `hop <cli name> …` (with `cli` in plugin.json5); `stdin` is set when piped.
    mutating func cli(_ cx: inout Context, args: [String], stdin: String?) throws -> CLIOutput
}

public extension HopPlugin {
    mutating func initialize(_ cx: inout Context) throws {}
    mutating func query(_ cx: inout Context, command: String, text: String) throws -> Response { .none }
    mutating func action(_ cx: inout Context, command: String, id: String, payload: JSONValue?) throws -> Response { .none }
    mutating func submit(_ cx: inout Context, command: String, text: String) throws -> Response { .none }
    mutating func answer(_ cx: inout Context, text: String) throws -> Answer? { nil }
    mutating func cli(_ cx: inout Context, args: [String], stdin: String?) throws -> CLIOutput {
        .fail("this plugin has no command line\n", code: 2)
    }
}

/// An error shown to the user as a failed HUD.
public struct PluginError: Error, CustomStringConvertible {
    public var description: String
    public init(_ message: String) { description = message }
}

private func send(_ message: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard var data = try? encoder.encode(message) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

/// Answers hop's requests until stdin closes or hop says `shutdown`.
public func serve<P: HopPlugin>(_ plugin: P) {
    var plugin = plugin
    var cx = Context()
    let decoder = JSONDecoder()
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let request = try? decoder.decode([String: JSONValue].self, from: Data(line.utf8)) else { continue }
        let id = request["id"]
        let params = request["params"] ?? .object([:])
        let method = request["method"]?.string ?? ""
        let command = params["command"]?.string ?? ""
        let result: Result<JSONValue, Error>
        do {
            switch method {
            case "initialize":
                let data = try JSONEncoder().encode(params)
                cx.initialize = (try? decoder.decode(Initialize.self, from: data)) ?? Initialize()
                try plugin.initialize(&cx)
                result = .success(.object(["protocolVersion": .number(Double(protocolVersion))]))
            case "run":
                result = .success(try encode(plugin.run(&cx, command: command, query: params["query"]?.string)))
            case "query":
                result = .success(try encode(plugin.query(&cx, command: command, text: params["text"]?.string ?? "")))
            case "action":
                result = .success(try encode(plugin.action(&cx, command: command, id: params["id"]?.string ?? "", payload: params["payload"])))
            case "submit":
                result = .success(try encode(plugin.submit(&cx, command: command, text: params["text"]?.string ?? "")))
            case "answer":
                let answer = try plugin.answer(&cx, text: params["text"]?.string ?? "")
                result = .success(try answer.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null)
            case "cli":
                var args: [String] = []
                if case .array(let list)? = params["args"] { args = list.compactMap(\.string) }
                let output = try plugin.cli(&cx, args: args, stdin: params["stdin"]?.string)
                result = .success(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(output)))
            case "shutdown":
                return
            default:
                throw PluginError("unknown method \(method)")
            }
        } catch {
            result = .failure(error)
        }
        guard let id, id != .null else { continue }
        switch result {
        case .success(let value): send(["jsonrpc": .string("2.0"), "id": id, "result": value])
        case .failure(let error):
            send(["jsonrpc": .string("2.0"), "id": id,
                  "error": .object(["code": .number(-32000), "message": .string("\(error)")])])
        }
    }
}

private func encode(_ response: Response) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
}
