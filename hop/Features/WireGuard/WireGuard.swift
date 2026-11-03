import AppKit

/// A WireGuard tunnel as listed by `scutil --nc list` (WireGuard.app registers
/// its tunnels as NetworkExtension VPN services).
nonisolated struct WireGuardTunnel: Sendable, Equatable {
    let name: String
    let serviceID: String
    let isConnected: Bool
    let status: String

    var flag: String { WireGuard.flag(for: name) }
    /// scutil reports Connecting / Disconnecting / Reasserting while the extension works.
    var isTransitioning: Bool { WireGuard.isTransitioning(status) }
    /// WireGuard.app wording: Activating → Activated, Deactivating → Deactivated.
    var label: String { WireGuard.label(for: status) }
}

/// Port of github.com/raycast/extensions/extensions/wireguard (MIT): list via
/// `scutil --nc list`, toggle via `scutil --nc start|stop <service id>`.
nonisolated enum WireGuard {
    static let scutil = "/usr/sbin/scutil"
    // * (Connected)      xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx VPN (com.wireguard.macos) "Home"   [VPN:com.wireguard.macos]
    private static var line: Regex<(Substring, Substring, Substring, Substring)> { /\* \((\w+)\)\s+([\w-]+?)\s+VPN\s+\(.*?"(.*?)"?\s+\[VPN:/ }

    static func parse(_ output: String) -> [WireGuardTunnel] {
        output.split(separator: "\n").compactMap { raw in
            let l = String(raw)
            guard l.contains("com.wireguard.macos"), let m = l.firstMatch(of: line) else { return nil }
            let status = String(m.1)
            return WireGuardTunnel(name: String(m.3), serviceID: String(m.2), isConnected: status == "Connected", status: status)
        }
        .sorted { a, b in
            a.isConnected != b.isConnected ? a.isConnected : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Country flag from a name prefix like "us-…" or "gb09-…"; 🏴‍☠️ otherwise.
    static func flag(for name: String) -> String {
        let pirate = "🏴‍☠️"
        guard let m = name.firstMatch(of: /^(\w{2})\d*?-/) else { return pirate }
        let code = m.1.uppercased()
        guard code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return pirate }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1A5 + $0.value) }))
    }

    static func isTransitioning(_ status: String) -> Bool {
        ["Connecting", "Disconnecting", "Reasserting"].contains(status)
    }

    static func label(for status: String) -> String {
        switch status {
        case "Connected": "Activated"
        case "Connecting", "Reasserting": "Activating…"
        case "Disconnecting": "Deactivating…"
        case "Disconnected": "Deactivated"
        default: status
        }
    }

    /// First line of `scutil --nc status <id>`: Connected, Connecting, Disconnecting, Disconnected…
    static func status(of tunnel: WireGuardTunnel) async -> String? {
        guard let r = try? await ProcessRunner.run(scutil, ["--nc", "status", tunnel.serviceID], timeout: .seconds(5)), r.ok,
              let first = r.out.split(separator: "\n").first else { return nil }
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// `scutil --nc start|stop` returns at once; poll until the extension reaches `on`, settles
    /// elsewhere, or `timeout` passes. Calls `progress` with each status seen; returns the last one.
    static func waitUntilSettled(_ tunnel: WireGuardTunnel, _ on: Bool, timeout: Duration = .seconds(20),
                                 progress: (String) async -> Void = { _ in }) async -> String? {
        let start = ContinuousClock.now
        let target = on ? "Connected" : "Disconnected"
        var last: String?
        while ContinuousClock.now - start < timeout {
            if let s = await status(of: tunnel) {
                if s != last { await progress(s) }
                last = s
                // Right after start/stop scutil may still report the old state for a moment.
                if s == target || (!isTransitioning(s) && ContinuousClock.now - start > .seconds(2)) { break }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return last
    }

    static func list() async -> [WireGuardTunnel] {
        #if DEBUG
        // A saved `scutil --nc list` output, for screenshots on a Mac without tunnels.
        if let path = UserDefaults.standard.string(forKey: "DebugWireGuardList"),
           let text = try? String(contentsOfFile: path, encoding: .utf8) { return parse(text) }
        #endif
        guard let r = try? await ProcessRunner.run(scutil, ["--nc", "list"], timeout: .seconds(10)), r.ok else { return [] }
        return parse(r.out)
    }

    static func setConnected(_ tunnel: WireGuardTunnel, _ on: Bool) async -> Bool {
        let r = try? await ProcessRunner.run(scutil, ["--nc", on ? "start" : "stop", tunnel.serviceID], timeout: .seconds(15))
        return r?.ok == true
    }

    /// Stops every connected tunnel; returns how many were stopped.
    static func disconnectAll() async -> Int {
        var n = 0
        for t in await list() where t.isConnected {
            if await setConnected(t, false) { n += 1 }
        }
        return n
    }
}

/// Sub-mode listing tunnels; ↵ toggles one.
final class WireGuardMode: Mode {
    let title: String? = "WireGuard"
    let tint: NSColor? = Palette.wireguard
    let placeholder = "Search tunnels…"
    private let showFlags: Bool
    private let sensitivity: Sensitivity
    private var tunnels: [WireGuardTunnel] = []
    private var loaded = false
    private weak var context: LauncherContext?

    init(showFlags: Bool, sensitivity: Sensitivity) {
        self.showFlags = showFlags
        self.sensitivity = sensitivity
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        refresh()
    }

    private func refresh(after delay: Duration? = nil) {
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            context?.setLoading(true)
            tunnels = await WireGuard.list()
            loaded = true
            context?.setLoading(false)
            context?.reload()
        }
    }

    private func chip(for t: WireGuardTunnel) -> Chip? {
        if t.isTransitioning { return Chip(text: t.label, tone: .warn) }
        return t.isConnected ? Chip(text: t.label, tone: .good) : nil
    }

    private func setStatus(_ status: String, of t: WireGuardTunnel) {
        guard let i = tunnels.firstIndex(where: { $0.serviceID == t.serviceID }) else { return }
        tunnels[i] = WireGuardTunnel(name: t.name, serviceID: t.serviceID, isConnected: status == "Connected", status: status)
        context?.reload()
    }

    /// Shows Activating…/Deactivating… on the row until scutil reports the tunnel settled.
    private func track(_ t: WireGuardTunnel, _ on: Bool) {
        setStatus(on ? "Connecting" : "Disconnecting", of: t)
        Task {
            let last = await WireGuard.waitUntilSettled(t, on) { [weak self] s in
                if WireGuard.isTransitioning(s) || s == (on ? "Connected" : "Disconnected") { self?.setStatus(s, of: t) }
            }
            refresh()
            switch last {
            case (on ? "Connected" : "Disconnected"):
                context?.showHUD("\(t.name) \(on ? "activated" : "deactivated")")
            case let s? where WireGuard.isTransitioning(s):
                context?.showHUD("\(t.name) is still \(WireGuard.label(for: s).lowercased())")
            default:
                context?.showHUD("\(t.name) did not \(on ? "activate" : "deactivate")")
            }
        }
    }

    func sections(for query: String) -> [ResultSection] {
        var list = tunnels
        if !query.isEmpty {
            let cands = list.map { RankCandidate(id: $0.serviceID, title: $0.name, typeWeight: 1) }
            list = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { list[$0] }
        }
        if loaded && tunnels.isEmpty {
            return [ResultSection(title: nil, items: [Item(
                id: "wg.none", title: "No WireGuard tunnels found",
                subtitle: "Install WireGuard from the App Store and add a tunnel",
                icon: .symbol("exclamationmark.triangle"), actions: [], tracksFrecency: false)])]
        }
        let items = list.map { t in
            Item(id: "wg." + t.serviceID, title: showFlags ? "\(t.flag) \(t.name)" : t.name, subtitle: t.label,
                 icon: .tile(t.isTransitioning ? "shield.lefthalf.filled" : t.isConnected ? "lock.shield.fill" : "shield.slash.fill",
                             t.isTransitioning ? Theme.warn : t.isConnected ? Theme.good : Palette.neutral),
                 accessory: t.isConnected || t.isTransitioning ? nil : "Deactivated",
                 actions: t.isTransitioning ? [] : [Action(title: t.isConnected ? "Deactivate" : "Activate") { [weak self] in
                     let on = !t.isConnected
                     guard await WireGuard.setConnected(t, on) else {
                         return .failWithHUD("scutil could not \(on ? "start" : "stop") \(t.name)")
                     }
                     self?.track(t, on)
                     return .stay
                 }], tracksFrecency: false, chip: chip(for: t))
        }
        return [ResultSection(title: "Tunnels", items: items)]
    }
}

enum WireGuardCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data
        guard config.wireguard.enabled else { return [] }
        return [
            Item(id: "wireguard.tunnels", title: "WireGuard", subtitle: "Connect or disconnect tunnels",
                 icon: .tile("network.badge.shield.half.filled", Palette.wireguard), accessory: "Command",
                 actions: [Action(title: "Show Tunnels") {
                     .push(WireGuardMode(showFlags: config.wireguard.showFlags, sensitivity: config.general.sensitivity))
                 }], pushesMode: true),
            Item(id: "wireguard.disconnectAll", title: "Disconnect All WireGuard Tunnels",
                 icon: .tile("network.slash", Palette.wireguard), accessory: "Command",
                 actions: [Action(title: "Disconnect All") {
                     let n = await WireGuard.disconnectAll()
                     return .dismissWithHUD(n == 0 ? "No tunnel was connected" : "Disconnected \(n) tunnel\(n == 1 ? "" : "s")")
                 }]),
        ]
    }
}
