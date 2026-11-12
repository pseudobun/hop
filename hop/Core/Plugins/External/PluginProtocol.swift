import Foundation

/// What a plugin process sends back: the hop plugin protocol (version 1). JSON-RPC 2.0, one
/// message per line on stdin/stdout. hop draws everything; a plugin only describes it.
/// The same shapes are in `sdk/` for Swift and Rust, and in docs/plugins.md.
nonisolated enum PluginProtocol {
    static let version = 1

    /// A plugin's answer to `run`, `query` and `action`, or the payload of a `render`
    /// notification. Every field is optional; several may be combined.
    struct Response: Codable, Equatable, Sendable {
        /// Replace the open view (or open it, for `run`).
        var view: View?
        /// Open a view on top of the current one.
        var push: View?
        /// Leave the current view.
        var pop: Bool?
        var hud: HUDMessage?
        /// Hide the launcher.
        var dismiss: Bool?
    }

    struct HUDMessage: Codable, Equatable, Sendable {
        enum Style: String, Codable, Sendable { case info, success, warn, fail }
        var text: String
        var style: Style?
    }

    struct View: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case list, grid }
        enum Filtering: String, Codable, Sendable {
            /// hop ranks the items as you type; the plugin hears nothing.
            case hop
            /// Every change of the search text goes to the plugin (`query`).
            case plugin
        }

        var type: Kind = .list
        /// Pill left of the search field.
        var title: String?
        var placeholder: String?
        var filtering: Filtering = .hop
        var columns: Int?
        var sections: [Section] = []
        /// Shown when there is nothing to list.
        var emptyText: String?
        /// A spinner until the next `render`.
        var loading: Bool?
        /// ↵ with no row selected sends the typed text (`submit`): text input, a prompt.
        var submit: Bool?
        /// The search field hides what is typed (a password).
        var secureInput: Bool?
    }

    struct Section: Codable, Equatable, Sendable {
        var title: String?
        var items: [Item] = []
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var subtitle: String?
        var icon: Icon?
        var accessory: String?
        var keywords: [String]?
        /// A tinted status chip: `{text, tone: neutral|good|warn|bad|info}`.
        var chip: ChipSpec?
        /// `actions[0]` runs on ↵.
        var actions: [Action] = []
    }

    struct ChipSpec: Codable, Equatable, Sendable {
        var text: String
        var tone: String?
    }

    /// Ask before an action runs: a screen with `message` and a confirm row.
    struct Confirm: Codable, Equatable, Sendable {
        var title: String?
        var message: String
        var button: String?
    }

    struct Icon: Codable, Equatable, Sendable {
        /// SF Symbol name, on a tile in `color` (or the plugin's colour).
        var symbol: String?
        var color: String?
        var emoji: String?
        /// Image file, absolute or relative to the plugin folder.
        var file: String?
    }

    struct Action: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Copies `value`.
            case copy
            /// Pastes `value` into the app behind hop.
            case paste
            /// Opens `url` (a web or app URL).
            case open
            /// Opens the file at `path`; `reveal` shows it in Finder.
            case openFile, reveal
            /// Opens `view` on top.
            case push
            /// Asks the plugin (`action` request with `id` and `payload`).
            case callback
        }

        var title: String
        var type: Kind
        var value: String?
        var url: String?
        var path: String?
        var view: View?
        var id: String?
        var payload: JSONValue?
        /// "cmd+c", "cmd+shift+return".
        var shortcut: String?
        var destructive: Bool?
        var confirm: Confirm?
    }

    // MARK: JSON-RPC

    struct Request<P: Encodable & Sendable>: Encodable, Sendable {
        var jsonrpc = "2.0"
        var id: Int?
        var method: String
        var params: P
    }

    struct Initialize: Codable, Equatable, Sendable {
        var protocolVersion = PluginProtocol.version
        var hopVersion: String
        var pluginID: String
        /// The plugin's settings, secrets included, by preference id.
        var preferences: [String: JSONValue]
        /// A folder the plugin may keep files in.
        var dataDir: String
        /// "dark" or "light".
        var appearance: String
    }

    struct Run: Codable, Equatable, Sendable {
        var command: String
        /// Text typed after the command's prefix, if any.
        var query: String?
        var background: Bool?
    }

    struct Query: Codable, Equatable, Sendable {
        var command: String
        var text: String
    }

    struct Submit: Codable, Equatable, Sendable {
        var command: String
        var text: String
    }

    struct Answer: Codable, Equatable, Sendable {
        var text: String
    }

    /// `hop <name> …`: the words after the name, and stdin when it is not a terminal.
    struct CLICall: Codable, Equatable, Sendable {
        var args: [String]
        var stdin: String?
    }

    struct CLIResult: Codable, Equatable, Sendable {
        var stdout: String?
        var stderr: String?
        var exitCode: Int?
    }

    /// `answer`'s reply: items for a root-search section.
    struct AnswerResult: Codable, Equatable, Sendable {
        var title: String?
        var items: [Item] = []
    }

    /// The `rootItems` notification: commands added to root search, and Upcoming items.
    struct RootItems: Codable, Equatable, Sendable {
        var items: [Item]?
        var upcoming: [Item]?
    }

    struct ActionCall: Codable, Equatable, Sendable {
        var command: String
        var id: String
        var payload: JSONValue?
    }

    /// One line from the plugin: a reply to a request (`id` with `result` or `error`), or a
    /// notification (`method` with `params`).
    struct Incoming: Decodable, Sendable {
        struct RPCError: Decodable, Sendable { var code: Int; var message: String }
        var id: Int?
        var result: JSONValue?
        var error: RPCError?
        var method: String?
        var params: JSONValue?
    }
}

nonisolated extension PluginProtocol.View {
    private enum Keys: String, CodingKey { case type, title, placeholder, filtering, columns, sections, items, emptyText, loading, submit, secureInput }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try c.value(.type, .list)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        filtering = try c.value(.filtering, .hop)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
        sections = try c.value(.sections, [])
        // `items` is a shorthand for one untitled section.
        if let items = try c.decodeIfPresent([PluginProtocol.Item].self, forKey: .items) {
            sections.insert(PluginProtocol.Section(title: nil, items: items), at: 0)
        }
        emptyText = try c.decodeIfPresent(String.self, forKey: .emptyText)
        loading = try c.decodeIfPresent(Bool.self, forKey: .loading)
        submit = try c.decodeIfPresent(Bool.self, forKey: .submit)
        secureInput = try c.decodeIfPresent(Bool.self, forKey: .secureInput)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encode(filtering, forKey: .filtering)
        try c.encodeIfPresent(columns, forKey: .columns)
        try c.encode(sections, forKey: .sections)
        try c.encodeIfPresent(emptyText, forKey: .emptyText)
        try c.encodeIfPresent(loading, forKey: .loading)
        try c.encodeIfPresent(submit, forKey: .submit)
        try c.encodeIfPresent(secureInput, forKey: .secureInput)
    }
}

nonisolated extension PluginProtocol.Section {
    private enum Keys: String, CodingKey { case title, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        items = try c.value(.items, [])
    }
}

nonisolated extension PluginProtocol.Item {
    private enum Keys: String, CodingKey { case id, title, subtitle, icon, accessory, keywords, chip, actions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(PluginProtocol.Icon.self, forKey: .icon)
        accessory = try c.decodeIfPresent(String.self, forKey: .accessory)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords)
        chip = try c.decodeIfPresent(PluginProtocol.ChipSpec.self, forKey: .chip)
        actions = try c.value(.actions, [])
    }
}

nonisolated extension PluginProtocol.AnswerResult {
    private enum Keys: String, CodingKey { case title, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        items = try c.value(.items, [])
    }
}
