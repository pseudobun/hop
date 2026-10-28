import AppKit

/// A WireGuard tunnel as listed by `scutil --nc list` (WireGuard.app registers
/// its tunnels as NetworkExtension VPN services).
nonisolated struct WireGuardTunnel: Sendable, Equatable {
    let name: String
    let serviceID: String
    let isConnected: Bool
    let status: String

    var flag: String { WireGuard.flag(for: name) }
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

    static func list() async -> [WireGuardTunnel] {
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
            Item(id: "wg." + t.serviceID, title: showFlags ? "\(t.flag) \(t.name)" : t.name, subtitle: t.status,
                 icon: .tile(t.isConnected ? "lock.shield.fill" : "shield.slash.fill", t.isConnected ? Theme.good : Palette.neutral),
                 accessory: t.isConnected ? nil : "Disconnected",
                 actions: [Action(title: t.isConnected ? "Disconnect" : "Connect") { [weak self] in
                     let ok = await WireGuard.setConnected(t, !t.isConnected)
                     self?.refresh(after: .seconds(1))
                     guard ok else { return .failWithHUD("scutil could not \(t.isConnected ? "stop" : "start") \(t.name)") }
                     return .dismissWithHUD("\(t.name) is \(t.isConnected ? "disconnected" : "connecting")")
                 }], tracksFrecency: false, chip: t.isConnected ? Chip(text: "Connected", tone: .good) : nil)
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
