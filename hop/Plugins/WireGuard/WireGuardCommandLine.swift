import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the WireGuard plugin.
extension WireGuardPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["wg"], usage: [
                "wg list | up <name> [--keep] | down <name> | down-all   WireGuard tunnels (WireGuard.app; up stops the others unless --keep)",
            ], run: CLI.wireguard),
        ]
    }
}

extension CLI {
    static func wireguard(_ a: Args) async -> Int32 {
        let tunnels = await WireGuard.list()
        let sub = a.positional.first ?? "list"
        let name = a.positional.dropFirst().joined(separator: " ")
        func find() -> WireGuardTunnel? {
            tunnels.first { $0.name == name } ?? tunnels.first { $0.name.lowercased().hasPrefix(name.lowercased()) }
        }
        switch sub {
        case "list":
            if a.json {
                Output.json(tunnels.map { ["name": $0.name, "serviceID": $0.serviceID, "status": $0.status, "connected": $0.isConnected] })
            } else if tunnels.isEmpty {
                print("no WireGuard tunnels")
            } else {
                for t in tunnels { print("\(t.isConnected ? "●" : "○") \(t.name)\t\(t.status)") }
            }
            return 0
        case "up", "down":
            guard !name.isEmpty, let t = find() else { return Output.fail("no tunnel named \(name)") }
            let on = sub == "up"
            if on && AppSettings().data.wireguard.exclusive && !a.flags.contains("keep") {
                for o in await WireGuard.stopOthers(than: t, in: tunnels) { print("\(o.name): deactivated") }
            }
            guard await WireGuard.setConnected(t, on) else { return Output.fail("scutil failed for \(t.name)") }
            print("\(t.name): \(on ? "activating" : "deactivating")…")
            let last = await WireGuard.waitUntilSettled(t, on)
            guard last == (on ? "Connected" : "Disconnected") else {
                return Output.fail("\(t.name): \(last.map(WireGuard.label(for:)) ?? "unknown")")
            }
            print("\(t.name): \(on ? "activated" : "deactivated")")
            return 0
        case "down-all":
            print("disconnected \(await WireGuard.disconnectAll())")
            return 0
        default:
            return Output.fail("usage: hop wg list | up <name> [--keep] | down <name> | down-all")
        }
    }
}
