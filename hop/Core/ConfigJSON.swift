import Foundation

/// The config as plain JSON values, and one-key reads and writes, for the CLI and agents.
enum ConfigJSON {
    /// Every key hop reads, defaults filled in: core, each plugin's section, `plugins`.
    static func effective(_ config: HopConfig) -> [String: Any] {
        var out: [String: Any] = [:]
        for child in Mirror(reflecting: config).children {
            guard let label = child.label, label != "sections", label != "plugins" else { continue }
            out[label] = plain(child.value)
        }
        for type in PluginConfigs.types {
            if let section = config.sections.section(type.key) { out[type.key] = plain(section.reflected) }
        }
        var plugins: [String: Any] = ["disabled": config.plugins.disabled]
        if let install = config.plugins.install { plugins["install"] = install }
        for (id, value) in config.plugins.settings { plugins[id] = value.plain ?? NSNull() }
        out["plugins"] = plugins
        return out
    }

    /// A value as JSONSerialization takes it: structs become objects, enums their raw value.
    static func plain(_ value: Any) -> Any {
        if let json = value as? JSONValue { return json.plain ?? NSNull() }
        if let raw = value as? any RawRepresentable { return plain(raw.rawValue) }
        if value is String || value is Bool || value is Int || value is Double { return value }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { plain($0.value) } ?? NSNull()
        case .collection, .set:
            return mirror.children.map { plain($0.value) }
        case .dictionary:
            var out: [String: Any] = [:]
            for pair in mirror.children {
                let kv = Array(Mirror(reflecting: pair.value).children)
                if kv.count == 2, let key = kv[0].value as? String { out[key] = plain(kv[1].value) }
            }
            return out
        case .struct, .class:
            var out: [String: Any] = [:]
            for child in mirror.children { if let label = child.label { out[label] = plain(child.value) } }
            return out
        default:
            return String(describing: value)
        }
    }

    /// `notes.folder`, `plugins."dev.you.x".name` → key path.
    static func path(_ text: String) -> [String]? {
        var out: [String] = [], current = "", quoted = false
        for c in text {
            switch c {
            case "\"" : quoted.toggle()
            case "." where !quoted:
                out.append(current)
                current = ""
            default: current.append(c)
            }
        }
        out.append(current)
        return quoted || out.contains(where: \.isEmpty) ? nil : out
    }

    static func value(at path: [String], in config: HopConfig) -> Any? {
        var node: Any = effective(config)
        for key in path {
            if let dict = node as? [String: Any], let next = dict[key] { node = next }
            else if let list = node as? [Any], let i = Int(key), list.indices.contains(i) { node = list[i] }
            else { return nil }
        }
        return node
    }

    /// JSON5 source for `raw`: itself when it reads as a JSON5 value, else a quoted string.
    static func literal(_ raw: String) -> String {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        if (try? decoder.decode([JSONValue].self, from: Data("[\(raw)]".utf8)))?.count == 1 { return raw }
        return ConfigEdit.literal(raw)
    }

    /// Writes one value and checks the config still reads; undoes the write if it doesn't.
    static func write(_ path: [String], _ raw: String, in settings: AppSettings) -> Int32 {
        let target = settings.url.resolvingSymlinksInPath()
        let before = try? String(contentsOf: target, encoding: .utf8)
        guard settings.update(path, to: literal(raw)) else { return CLI.Output.fail("could not write \(display(path))") }
        if let error = settings.error {
            if let before { try? before.write(to: target, atomically: true, encoding: .utf8) }
            return CLI.Output.fail("not written, the config would not read: \(error.message)")
        }
        for warning in settings.warnings { print("warning: \(warning.message)") }
        print("\(display(path)) = \(literal(raw))")
        return 0
    }
}
