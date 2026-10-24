import AppKit

/// The `hotkeys` section of the config: a global hotkey for any root command or app.
/// Keys are a command id (`system.emptyTrash`), a command title (`Empty Trash`), an
/// app name (`Safari`) or `app:` plus a bundle id (`app:com.apple.Safari`).
final class HotkeyBindings {
    private var bound: [GlobalHotkey] = []
    /// Bindings that could not be set up, for the launcher's Setup section.
    private(set) var problems: [String] = []
    var run: ((String) -> Void)?

    /// Re-registers every binding. `reserved` are hop's own hotkeys (launcher, notes, clipboard).
    func apply(_ map: [String: String], reserved: [(owner: String, hotkey: String)]) {
        bound.forEach { $0.unregister() }
        bound = []
        problems = []
        var used: [HotkeySpec: String] = [:]
        for r in reserved { if let s = HotkeySpec.parse(r.hotkey) { used[s] = r.owner } }
        for (key, text) in map.sorted(by: { $0.key < $1.key }) {
            guard let spec = HotkeySpec.parse(text) else {
                problems.append("“\(text)” for \(key) is not a hotkey")
                continue
            }
            if let owner = used[spec] {
                problems.append("\(text) for \(key) is already \(owner)")
                continue
            }
            let hotkey = GlobalHotkey { [weak self] in self?.run?(key) }
            if hotkey.register(keyCode: spec.keyCode, modifiers: spec.modifiers) {
                bound.append(hotkey)
                used[spec] = key
            } else {
                problems.append("\(text) for \(key) is taken by another app or macOS")
            }
        }
    }
}

nonisolated enum HotkeyLookup {
    /// The hotkey bound to an item: by id, by title (any case), or for apps by bundle id.
    static func binding(id: String, title: String, bundleID: String? = nil, in map: [String: String]) -> String? {
        if let h = map[id] { return h }
        if let bundleID, let h = map[bundleID] ?? map["app:" + bundleID] { return h }
        return map.first { $0.key.caseInsensitiveCompare(title) == .orderedSame }?.value
    }
}
