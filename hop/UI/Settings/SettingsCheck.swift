import AppKit

/// Something wrong with a Settings value. An error is not saved; a warning is saved and shown.
struct SettingsProblem: Equatable {
    enum Level { case warning, error }
    let level: Level
    let message: String

    static func warning(_ message: String) -> SettingsProblem { SettingsProblem(level: .warning, message: message) }
    static func error(_ message: String) -> SettingsProblem { SettingsProblem(level: .error, message: message) }
}

/// Checks a field's value as it is typed: a `String` for text, `[String]` for a list, `Int` for
/// a number. Nil when it is fine.
typealias SettingsCheck = (Any) -> SettingsProblem?

/// The checks fields use.
enum SettingsChecks {
    private static func text(_ value: Any) -> String { (value as? String ?? "").trimmingCharacters(in: .whitespaces) }
    private static func list(_ value: Any) -> [String] { value as? [String] ?? [] }

    private static func isDirectory(_ path: String) -> Bool? {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.expandingTilde, isDirectory: &dir) else { return nil }
        return dir.boolValue
    }

    /// A folder that should exist. Empty passes when `optional`.
    static func folder(optional: Bool = false) -> SettingsCheck {
        { value in
            let path = text(value)
            if path.isEmpty { return optional ? nil : .error("Enter a folder") }
            switch isDirectory(path) {
            case nil: return .warning("No folder at \(path) yet")
            case false?: return .error("\(path) is a file, not a folder")
            case true?: return nil
            }
        }
    }

    /// Every entry a folder.
    static let folders: SettingsCheck = { value in
        let paths = list(value)
        if paths.isEmpty { return .error("Enter at least one folder") }
        let missing = paths.filter { isDirectory($0) != true }
        return missing.isEmpty ? nil : .warning("Not a folder: \(missing.joined(separator: ", "))")
    }

    /// A file that should exist (it may be created later).
    static let file: SettingsCheck = { value in
        let path = text(value)
        if path.isEmpty { return .error("Enter a file") }
        switch isDirectory(path) {
        case nil: return .warning("No file at \(path) yet; hop creates it when needed")
        case true?: return .error("\(path) is a folder, not a file")
        case false?: return nil
        }
    }

    /// A program hop can run; empty means "find it".
    static let executable: SettingsCheck = { value in
        let path = text(value)
        if path.isEmpty { return nil }
        if !FileManager.default.fileExists(atPath: path.expandingTilde) { return .error("No program at \(path)") }
        return FileManager.default.isExecutableFile(atPath: path.expandingTilde) ? nil : .error("\(path) is not executable")
    }

    /// Bundle identifiers; an app that is not installed is only a warning.
    static let bundleIDs: SettingsCheck = { value in
        let ids = list(value)
        let malformed = ids.filter { $0.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil }
        if !malformed.isEmpty { return .error("Not a bundle identifier: \(malformed.joined(separator: ", ")) (like com.apple.Terminal)") }
        let missing = ids.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }
        return missing.isEmpty ? nil : .warning("Not installed: \(missing.joined(separator: ", "))")
    }

    /// Two ISO 639 language codes, or none.
    static let languagePair: SettingsCheck = { value in
        let codes = list(value)
        if codes.isEmpty { return nil }
        if codes.count != 2 { return .error("Two codes (\"sl, en\"), or empty for your macOS language and English") }
        let known = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
        let unknown = codes.filter { !known.contains($0.lowercased()) }
        if !unknown.isEmpty { return .error("Unknown language code: \(unknown.joined(separator: ", "))") }
        return codes[0].lowercased() == codes[1].lowercased() ? .error("Pick two different languages") : nil
    }

    /// A currency code such as EUR.
    static let currency: SettingsCheck = { value in
        let code = text(value).uppercased()
        if code.isEmpty { return .error("Enter a currency code, like EUR") }
        return Locale.commonISOCurrencyCodes.contains(code) ? nil : .error("Unknown currency code \(code)")
    }

    /// Modifier keys ("shift", "ctrl+alt"); empty is off.
    static let modifiers: SettingsCheck = { value in
        let parts = text(value).lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        let allowed: Set<String> = ["shift", "ctrl", "control", "alt", "opt", "option", "cmd", "command", "hyper"]
        let unknown = parts.filter { !allowed.contains($0) }
        return unknown.isEmpty ? nil : .error("Not a modifier: \(unknown.joined(separator: ", ")) (shift, ctrl, alt, cmd)")
    }

    /// Fallback ids (chatgpt, google, github) or URLs with {query}.
    static let fallbacks: SettingsCheck = { value in
        let bad = list(value).filter { FallbackSearch.engine($0) == nil }
        return bad.isEmpty ? nil : .error("Not chatgpt, google, github or a URL with {query}: \(bad.joined(separator: ", "))")
    }

    /// A folder name inside another folder, not a path out of it.
    static let relativeFolder: SettingsCheck = { value in
        let path = text(value)
        if path.hasPrefix("/") || path.hasPrefix("~") { return .error("A folder inside the notes folder, like Inbox") }
        return path.split(separator: "/").contains("..") ? .error("Stay inside the notes folder (no ..)") : nil
    }

    /// Anything but empty.
    static let required: SettingsCheck = { value in
        if let s = value as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty ? .error("Required") : nil }
        if let l = value as? [String] { return l.isEmpty ? .error("Required") : nil }
        return nil
    }
}

extension SettingsCatalog {
    /// The field for a config key path, among hop's and the built-in plugins' pages.
    static func field(at path: [String]) -> SettingsField? {
        pages.lazy.flatMap(\.fields).first { $0.path == path }
    }

    /// What the field checks say about the config's current values, as "key: message".
    static func problems(in config: HopConfig) -> [(key: String, problem: SettingsProblem)] {
        pages.flatMap(\.fields).compactMap { field in
            guard let check = field.check, let value = SettingsValue.read(field.path, in: config),
                  let problem = check(value) else { return nil }
            return (field.key, problem)
        }
    }
}
