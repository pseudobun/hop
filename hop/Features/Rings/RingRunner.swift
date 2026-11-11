import AppKit
import Carbon
import IOKit.pwr_mgt
import UniformTypeIdentifiers

/// The world at the moment a ring opened: the app in front, the pointer.
struct RingContext {
    let app: NSRunningApplication?
    let point: NSPoint
}

/// What running a slice led to.
enum RingOutcome {
    case done
    case hud(String)
    case warn(String)
    case fail(String)
    /// More choices, shown as a new ring that stays open until one is clicked.
    case fan(String, [RingNode])
}

/// A slice as the ring draws and runs it.
struct RingNode {
    enum Kind {
        case run(statsKey: String, (RingContext) async -> RingOutcome)
        case group([RingNode])
        /// Shown faded; pointing at it says why.
        case broken(String)
    }

    var title: String
    var symbol: String
    var image: NSImage?
    var tint: NSColor?
    var kind: Kind
    /// Read when the ring opens; nil is no switch.
    var readState: (() async -> Bool?)?

    var isGroup: Bool { if case .group = kind { true } else { false } }
}

/// Turns config slices into `RingNode`s and runs built-in actions.
enum RingRunner {
    /// hop's own commands and apps by key, as in `hotkeys` (AppDelegate.runBinding).
    nonisolated(unsafe) static var runHopBinding: ((String) -> Void)?
    /// Titles and symbols of hop's root commands, for slices that name one.
    nonisolated(unsafe) static var hopCommand: ((String) -> Item?)?

    static func node(_ slice: HopConfig.Slice) -> RingNode {
        if !slice.children.isEmpty {
            let children = slice.children.prefix(8).map(node)
            return RingNode(title: slice.title.isEmpty ? "Group" : slice.title,
                            symbol: slice.icon.isEmpty ? "circle.grid.2x2.fill" : slice.icon, kind: .group(Array(children)))
        }
        guard let ref = RingActionRef.parse(slice.action) else {
            return RingNode(title: slice.title.isEmpty ? "?" : slice.title, symbol: "questionmark.circle",
                            kind: .broken("“\(slice.action)” is not an action"))
        }
        var n = node(ref)
        if !slice.title.isEmpty { n.title = slice.title }
        if !slice.icon.isEmpty { n.symbol = slice.icon; n.image = nil }
        return n
    }

    static func node(_ ref: RingActionRef) -> RingNode {
        switch ref {
        case .builtin(let id):
            let e = RingCatalog.entry(id)!
            let entryID = e.id
            let run: (RingContext) async -> RingOutcome = { ctx in await runBuiltin(entryID, ctx) }
            var read: (() async -> Bool?)?
            if e.isSwitch { read = { await state(of: entryID) } }
            return RingNode(title: e.title, symbol: e.symbol, kind: .run(statsKey: entryID, run), readState: read)
        case .command(let key):
            let item = hopCommand?(key)
            var symbol = "command"
            if case .tile(let s, _)? = item?.icon { symbol = s }
            if case .symbol(let s, _)? = item?.icon { symbol = s }
            return RingNode(title: item?.title ?? key, symbol: symbol, kind: .run(statsKey: "hop:" + key) { _ in
                runHopBinding?(key)
                return .done
            })
        case .app(let name):
            let url = appURL(name)
            let title = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? name
            return RingNode(title: title, symbol: "app", image: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                            kind: url == nil ? .broken("\(name) is not installed") : .run(statsKey: "app:" + name) { _ in
                                openApp(url!)
                                return .done
                            })
        case .key(let stroke):
            return RingNode(title: "Keystroke", symbol: "keyboard", kind: .run(statsKey: "key") { ctx in
                ctx.app?.activate()
                stroke.post()
                return .done
            })
        case .type(let text):
            return RingNode(title: String(text.prefix(18)), symbol: "character.cursor.ibeam", kind: .run(statsKey: "type") { ctx in
                ctx.app?.activate()
                TextTyper.type(text)
                return .done
            })
        case .menu(let path):
            return RingNode(title: path.last!, symbol: "filemenu.and.selection", kind: .run(statsKey: "menu:" + path.joined(separator: ">")) { ctx in
                guard let app = ctx.app else { return .fail("No app was in front") }
                return MenuPress.press(path, in: app) ? .done : .fail("No menu item \(path.joined(separator: " › "))")
            })
        case .shortcut(let name):
            return RingNode(title: name, symbol: "square.2.layers.3d.fill", kind: .run(statsKey: "shortcut:" + name) { _ in
                let r = try? await ProcessRunner.run("/usr/bin/shortcuts", ["run", name], timeout: .seconds(300))
                return r?.ok == true ? .done : .fail("Shortcut “\(name)” failed")
            })
        case .url(let text):
            let url = URL(string: text)
            let host = url?.host()?.replacingOccurrences(of: "www.", with: "")
            return RingNode(title: host ?? text, symbol: "link", kind: url == nil ? .broken("\(text) is not a link") : .run(statsKey: "url") { _ in
                NSWorkspace.shared.open(url!) ? .done : .fail("Could not open \(text)")
            })
        case .folder(let path):
            let url = URL(fileURLWithPath: path.expandingTilde)
            return RingNode(title: url.lastPathComponent, symbol: "folder.fill", image: NSWorkspace.shared.icon(forFile: url.path),
                            kind: .run(statsKey: "folder") { _ in
                                NSWorkspace.shared.open(url) ? .done : .fail("No folder \(path)")
                            })
        case .shell(let command):
            return RingNode(title: String(command.prefix(18)), symbol: "terminal", kind: .run(statsKey: "shell") { _ in
                let r = try? await ProcessRunner.run("/bin/zsh", ["-lc", command], timeout: .seconds(300))
                guard let r else { return .fail("Could not run the command") }
                let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.ok { return .fail(r.err.isEmpty ? "Exit \(r.status)" : String(r.err.prefix(120))) }
                return out.isEmpty ? .done : .hud(String(out.prefix(120)))
            })
        case .appleScript(let source):
            return RingNode(title: "AppleScript", symbol: "applescript", kind: .run(statsKey: "applescript") { _ in
                let r = try? await AppleScript.run(source)
                return r?.ok == true ? .done : .fail(String((r?.err ?? "AppleScript failed").prefix(120)))
            })
        }
    }

    static func appURL(_ name: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "~/Applications".expandingTilde,
                    "/System/Library/CoreServices"] {
            let url = URL(fileURLWithPath: dir).appending(path: name.hasSuffix(".app") ? name : name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Like a hop app hotkey: brings it forward, or opens it.
    static func openApp(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Built-ins

    static func runBuiltin(_ id: String, _ ctx: RingContext) async -> RingOutcome {
        switch id {
        case "dark-mode":
            return await script(#"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#)
        case "night-shift":
            guard let on = NightShift.isOn() else { return .fail("Night Shift is not available") }
            NightShift.set(!on)
            return .done
        case "keep-awake":
            KeepAwake.toggle()
            return .hud(KeepAwake.isOn ? "Keeping awake" : "Sleep as usual")
        case "mute":
            return await script("set volume output muted (not (output muted of (get volume settings)))")
        case "mic-mute":
            return await MicMute.toggle()
        case "volume-up":
            return await script("set volume output volume ((output volume of (get volume settings)) + 6.25)")
        case "volume-down":
            return await script("set volume output volume ((output volume of (get volume settings)) - 6.25)")
        case "bluetooth":
            guard let on = BluetoothPower.isOn() else { return .fail("Bluetooth is not available") }
            return BluetoothPower.set(!on) ? .done : .fail("Could not switch Bluetooth")
        case "lock-screen": KeyStroke.parse("ctrl+cmd+q")!.post(); return .done
        case "sleep": return await run("/usr/bin/pmset", ["sleepnow"])
        case "displays-off": return await run("/usr/bin/pmset", ["displaysleepnow"])
        case "screen-saver": return await run("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        case "input-source": return InputSources.selectNext() ? .done : .fail("Only one keyboard language is enabled")
        case "input-sources": return InputSources.fan()
        case "eject-all": return await Ejector.ejectAll()
        case "hidden-files": return await finderDefault("AppleShowAllFiles", domain: "com.apple.finder", restart: "Finder")
        case "file-extensions": return await finderDefault("AppleShowAllExtensions", domain: "NSGlobalDomain", restart: "Finder")
        case "path-bar": return await finderDefault("ShowPathbar", domain: "com.apple.finder", restart: "Finder")
        case "desktop-icons": return await finderDefault("CreateDesktop", domain: "com.apple.finder", restart: "Finder", defaultOn: true)
        case "dock-recents": return await finderDefault("show-recents", domain: "com.apple.dock", restart: "Dock", defaultOn: true)
        case "user-library":
            let hidden = (try? URL(fileURLWithPath: "~/Library".expandingTilde).resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? true
            return await run("/usr/bin/chflags", [hidden ? "nohidden" : "hidden", "~/Library".expandingTilde])
        case "dock-autohide":
            return await script(#"tell application "System Events" to tell dock preferences to set autohide to not autohide"#)
        case "menu-bar-autohide":
            return await script(#"tell application "System Events" to tell dock preferences to set autohide menu bar to not autohide menu bar"#)
        case "clear-derived-data":
            let dir = URL(fileURLWithPath: "~/Library/Developer/Xcode/DerivedData".expandingTilde)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if items.isEmpty { return .warn("DerivedData is already empty") }
            let failed = await DownloadsScanner.trash(items)
            return failed == 0 ? .hud("DerivedData cleared") : .fail("\(failed) items could not be moved")
        case "screenshot-tools": return key("shift+cmd+5")
        case "screenshot-area": return key("ctrl+shift+cmd+4")
        case "screenshot-screen": return key("ctrl+shift+cmd+3")
        case "emoji-picker": return key("ctrl+cmd+space", ctx)
        case "mission-control": return missionControl(nil)
        case "app-windows": return missionControl("2")
        case "show-desktop": return missionControl("1")
        case "previous-desktop": return key("ctrl+left")
        case "next-desktop": return key("ctrl+right")
        case "previous-app":
            guard let app = AppHistory.shared.previous(before: ctx.app) else { return .warn("No previous app yet") }
            app.activate()
            return .done
        case "switch-app": return switchAppFan()
        case "hide-others": return HideOthers.toggle(keeping: ctx.app)
        case "full-screen": return key("ctrl+cmd+f", ctx)
        case "minimize": return key("cmd+m", ctx)
        case "close-window": return key("cmd+w", ctx)
        case "hide-app": ctx.app?.hide(); return .done
        case "quit-app":
            guard let app = ctx.app else { return .fail("No app was in front") }
            app.terminate()
            return .done
        case "force-quit-app":
            guard let app = ctx.app, app.bundleIdentifier != "com.apple.finder" else { return .fail("No app to force quit") }
            return app.forceTerminate() ? .hud("Force quit \(app.localizedName ?? "the app")") : .fail("Could not force quit")
        case "force-quit": return key("alt+cmd+escape")
        case "play-pause": MediaKeys.press(.playPause); return .done
        case "next-track": MediaKeys.press(.next); return .done
        case "previous-track": MediaKeys.press(.previous); return .done
        case "shuffle": return await Player.toggle(music: "shuffle enabled", spotify: "shuffling")
        case "repeat": return await Player.toggleRepeat()
        case "copy-path", "copy-name", "copy-files", "airdrop", "move-to", "copy-to", "convert", "compress", "new-folder",
             "show-info", "open-terminal", "open-vscode":
            return await FinderActions.run(id)
        case "claude-model": return ClaudeCode.modelFan(ctx)
        default: return .fail("Unknown action \(id)")
        }
    }

    /// On or off, for switches; nil when it cannot be read.
    static func state(of id: String) async -> Bool? {
        switch id {
        case "dark-mode": return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        case "night-shift": return NightShift.isOn()
        case "keep-awake": return KeepAwake.isOn
        case "mute": return await scriptBool("output muted of (get volume settings)")
        case "mic-mute": return await scriptBool("(input volume of (get volume settings)) = 0")
        case "bluetooth": return BluetoothPower.isOn()
        case "hidden-files": return await readDefault("AppleShowAllFiles", domain: "com.apple.finder") ?? false
        case "file-extensions": return await readDefault("AppleShowAllExtensions", domain: "NSGlobalDomain") ?? false
        case "path-bar": return await readDefault("ShowPathbar", domain: "com.apple.finder") ?? false
        case "desktop-icons": return await readDefault("CreateDesktop", domain: "com.apple.finder") ?? true
        case "dock-recents": return await readDefault("show-recents", domain: "com.apple.dock") ?? true
        case "user-library":
            return !((try? URL(fileURLWithPath: "~/Library".expandingTilde).resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? true)
        case "dock-autohide": return await readDefault("autohide", domain: "com.apple.dock") ?? false
        case "menu-bar-autohide": return await readDefault("_HIHideMenuBar", domain: "NSGlobalDomain") ?? false
        case "hide-others": return HideOthers.hidden.isEmpty == false
        case "shuffle": return await Player.state(music: "shuffle enabled", spotify: "shuffling")
        case "repeat": return await Player.repeatState()
        default: return nil
        }
    }

    // MARK: Helpers

    static func key(_ text: String, _ ctx: RingContext? = nil) -> RingOutcome {
        ctx?.app?.activate()
        KeyStroke.parse(text)?.post()
        return .done
    }

    static func script(_ source: String) async -> RingOutcome {
        let r = try? await AppleScript.run(source)
        return r?.ok == true ? .done : .fail(String((r?.err ?? "AppleScript failed").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
    }

    static func scriptBool(_ source: String) async -> Bool? {
        guard let r = try? await AppleScript.run("return " + source), r.ok else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func run(_ exe: String, _ args: [String]) async -> RingOutcome {
        let r = try? await ProcessRunner.run(exe, args, timeout: .seconds(30))
        return r?.ok == true ? .done : .fail(String((r?.err ?? "\(exe) failed").prefix(120)))
    }

    static func readDefault(_ key: String, domain: String) async -> Bool? {
        guard let r = try? await ProcessRunner.run("/usr/bin/defaults", ["read", domain, key], timeout: .seconds(5)), r.ok
        else { return nil }
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes"
    }

    static func finderDefault(_ key: String, domain: String, restart: String, defaultOn: Bool = false) async -> RingOutcome {
        let on = await readDefault(key, domain: domain) ?? defaultOn
        guard (try? await ProcessRunner.run("/usr/bin/defaults", ["write", domain, key, "-bool", on ? "false" : "true"]))?.ok == true
        else { return .fail("Could not write \(key)") }
        _ = try? await ProcessRunner.run("/usr/bin/killall", [restart])
        return .done
    }

    static func missionControl(_ arg: String?) -> RingOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        p.arguments = arg.map { [$0] } ?? []
        do { try p.run() } catch { return .fail("Mission Control did not open") }
        return .done
    }

    static func switchAppFan() -> RingOutcome {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        guard !apps.isEmpty else { return .warn("No other running app") }
        let nodes = apps.prefix(8).map { app in
            RingNode(title: app.localizedName ?? "App", symbol: "app", image: app.icon, kind: .run(statsKey: "switch-app") { _ in
                app.unhide()
                app.activate()
                return .done
            })
        }
        return .fan("Switch App", Array(nodes))
    }
}

// MARK: - Small system services

/// Remembers which app was in front before, for "Previous App".
final class AppHistory {
    static let shared = AppHistory()
    private var order: [pid_t] = []
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.order.removeAll { $0 == app.processIdentifier }
                self.order.insert(app.processIdentifier, at: 0)
                if self.order.count > 20 { self.order.removeLast() }
            }
        }
    }

    func previous(before app: NSRunningApplication?) -> NSRunningApplication? {
        let skip = app?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        for pid in order where pid != skip && pid != getpid() {
            if let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated, a.activationPolicy == .regular { return a }
        }
        return nil
    }
}

enum KeepAwake {
    private nonisolated(unsafe) static var assertion: IOPMAssertionID = 0
    static var isOn: Bool { assertion != 0 }

    static func toggle() {
        if isOn {
            IOPMAssertionRelease(assertion)
            assertion = 0
        } else {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), "hop Keep Awake" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        }
    }
}

enum MicMute {
    private nonisolated(unsafe) static var remembered = 70

    static func toggle() async -> RingOutcome {
        guard let r = try? await AppleScript.run("return input volume of (get volume settings)"), r.ok,
              let level = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .fail("No microphone") }
        if level > 0 {
            remembered = level
            _ = try? await AppleScript.run("set volume input volume 0")
            return .hud("Microphone muted")
        }
        _ = try? await AppleScript.run("set volume input volume \(remembered)")
        return .hud("Microphone on")
    }
}

enum HideOthers {
    nonisolated(unsafe) static var hidden: [pid_t] = []

    static func toggle(keeping front: NSRunningApplication?) -> RingOutcome {
        if !hidden.isEmpty {
            for pid in hidden { NSRunningApplication(processIdentifier: pid)?.unhide() }
            hidden = []
            return .done
        }
        let keep = front?.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != keep && !app.isHidden && app.processIdentifier != getpid() {
            if app.hide() { hidden.append(app.processIdentifier) }
        }
        return .done
    }
}

/// Play, next and previous as the media keys send them, so any player answers.
enum MediaKeys {
    enum Key: Int32 { case playPause = 16, next = 17, previous = 18 }

    static func press(_ key: Key) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Shuffle and repeat in Music or Spotify, whichever is playing.
enum Player {
    static func running() -> String? {
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if ids.contains("com.spotify.client") { return "Spotify" }
        if ids.contains("com.apple.Music") { return "Music" }
        return nil
    }

    static func toggle(music: String, spotify: String) async -> RingOutcome {
        guard let app = running() else { return .warn("Neither Music nor Spotify is open") }
        let prop = app == "Music" ? music : spotify
        return await RingRunner.script("tell application \"\(app)\" to set \(prop) to not \(prop)")
    }

    static func state(music: String, spotify: String) async -> Bool? {
        guard let app = running() else { return nil }
        return await RingRunner.scriptBool("(tell application \"\(app)\" to get \(app == "Music" ? music : spotify))")
    }

    static func toggleRepeat() async -> RingOutcome {
        guard let app = running() else { return .warn("Neither Music nor Spotify is open") }
        if app == "Spotify" { return await toggle(music: "", spotify: "repeating") }
        return await RingRunner.script(#"tell application "Music" to if song repeat is off then set song repeat to all else set song repeat to off"#)
    }

    static func repeatState() async -> Bool? {
        guard let app = running() else { return nil }
        if app == "Spotify" { return await RingRunner.scriptBool(#"(tell application "Spotify" to get repeating)"#) }
        return await RingRunner.scriptBool(#"(tell application "Music" to get song repeat) is not off"#)
    }
}

enum InputSources {
    static func enabled() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list
    }

    static func name(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyLocalizedName) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func id(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func selectNext() -> Bool {
        let all = enabled()
        guard all.count > 1 else { return false }
        let current = id(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        let i = all.firstIndex { id($0) == current } ?? -1
        return TISSelectInputSource(all[(i + 1) % all.count]) == noErr
    }

    static func fan() -> RingOutcome {
        let all = enabled()
        guard all.count > 1 else { return .warn("Only one keyboard language is enabled") }
        return .fan("Keyboard Languages", all.prefix(8).map { s in
            RingNode(title: name(s), symbol: "keyboard", kind: .run(statsKey: "input-sources") { _ in
                TISSelectInputSource(s) == noErr ? .done : .fail("Could not switch")
            })
        })
    }
}

enum Ejector {
    static func ejectAll() async -> RingOutcome {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let ejectable = volumes.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsRootFileSystem != true && v.volumeIsLocal == true && (v.volumeIsEjectable == true || v.volumeIsRemovable == true)
        }
        guard !ejectable.isEmpty else { return .warn("No disks to eject") }
        var failed = 0
        for url in ejectable {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failed += 1 }
        }
        let n = ejectable.count - failed
        return failed == 0 ? .hud("Ejected \(n) disk\(n == 1 ? "" : "s")") : .fail("\(failed) disk\(failed == 1 ? "" : "s") in use")
    }
}

/// Night Shift through CoreBrightness, the framework System Settings uses.
enum NightShift {
    private nonisolated(unsafe) static var client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static func isOn() -> Bool? {
        guard let client else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        // Status struct: active, enabled, sunSchedulePermitted, mode, schedule…; 64 bytes is ample.
        let status = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { status.deallocate() }
        status.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        guard fn(client, sel, status) else { return nil }
        return status.load(fromByteOffset: 1, as: Bool.self)
    }

    static func set(_ on: Bool) {
        guard let client else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, on)
    }
}

/// Bluetooth power through IOBluetooth's preference calls (what `blueutil` uses).
enum BluetoothPower {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void
    private nonisolated(unsafe) static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    static func isOn() -> Bool? {
        guard let handle, let sym = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(sym, to: Get.self)() != 0
    }

    static func set(_ on: Bool) -> Bool {
        guard let handle, let sym = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return false }
        unsafeBitCast(sym, to: Set.self)(on ? 1 : 0)
        return true
    }
}

/// Types text into the app in front, as keyboard events.
enum TextTyper {
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { KeyStroke.parse("return")!.post() }
            let chars = Array(String(line.element).utf16)
            var i = 0
            while i < chars.count {
                let chunk = Array(chars[i..<min(i + 20, chars.count)])
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                    e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    e.post(tap: .cghidEventTap)
                }
                i += 20
            }
        }
    }
}

/// Clicks a menu item of an app by its titles, through Accessibility.
enum MenuPress {
    static func press(_ path: [String], in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard var element = attribute(root, kAXMenuBarAttribute) else { return false }
        for (i, title) in path.enumerated() {
            guard let item = children(element).first(where: { matches($0, title) }) else { return false }
            if i == path.count - 1 { return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success }
            // A menu bar item or menu item holds its menu as the only child.
            guard let menu = children(item).first else { return false }
            element = menu
        }
        return false
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func matches(_ e: AXUIElement, _ title: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &value) == .success, let t = value as? String
        else { return false }
        let norm = { (s: String) in s.replacingOccurrences(of: "…", with: "...").lowercased() }
        return norm(t) == norm(title)
    }
}

/// Claude Code's `/model` command, typed into the terminal in front.
enum ClaudeCode {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.github.wez.wezterm",
                                         "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "io.alacritty", "com.superlogical.rex"]

    static func modelFan(_ ctx: RingContext) -> RingOutcome {
        guard let app = ctx.app, let id = app.bundleIdentifier, terminals.contains(id)
        else { return .warn("Bring the terminal that runs Claude Code to the front first") }
        let models = [("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku"), ("Default", "default")]
        return .fan("Claude Code Model", models.map { title, alias in
            RingNode(title: title, symbol: "cpu", kind: .run(statsKey: "claude-model") { _ in
                app.activate()
                TextTyper.type("/model \(alias)\n")
                return .done
            })
        })
    }
}
