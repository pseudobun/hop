import Foundation

/// `hop` CLI commands of the ExpressVPN plugin.
extension ExpressVPNPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["vpn", "expressvpn"], usage: [
                "vpn [status] | regions [query] | connect [region] | disconnect | select <region>   ExpressVPN (expressvpnctl)",
            ], run: CLI.expressvpn),
        ]
    }
}

extension CLI {
    static func expressvpn(_ a: Args) async -> Int32 {
        guard ExpressVPN.executable != nil else { return Output.fail("expressvpnctl not found; install ExpressVPN.app") }
        let sub = a.positional.first ?? "status"
        let arg = a.positional.dropFirst().joined(separator: " ")
        func region() async -> String?? {
            guard !arg.isEmpty else { return .some(nil) }
            return ExpressVPN.resolve(arg, in: await ExpressVPN.regions()).map { .some($0) }
        }
        switch sub {
        case "status":
            async let s = ExpressVPN.state(), r = ExpressVPN.region(), ip = ExpressVPN.vpnIP()
            let (state, selected, vpnIP) = await (s, r, ip)
            guard let state else { return Output.fail("expressvpnctl did not answer; is ExpressVPN running?") }
            if a.json {
                Output.json(["state": state, "connected": ExpressVPN.isConnected(state), "region": selected ?? "",
                             "regionName": selected.map(ExpressVPN.name(of:)) ?? "", "vpnIP": vpnIP ?? ""] as [String: Any])
            } else {
                let place = selected.map { "\t\(ExpressVPN.flag(for: $0)) \(ExpressVPN.name(of: $0))" } ?? ""
                print("\(ExpressVPN.isConnected(state) ? "●" : "○") \(state)\(place)\(vpnIP.map { "\t\($0)" } ?? "")")
            }
            return 0
        case "regions", "list":
            let q = arg.lowercased()
            let all = await ExpressVPN.regions().filter {
                q.isEmpty || $0.contains(q.replacingOccurrences(of: " ", with: "-")) || ExpressVPN.name(of: $0).lowercased().contains(q)
            }
            if a.json {
                Output.json(all.map { ["region": $0, "name": ExpressVPN.name(of: $0), "country": ExpressVPN.country(of: $0) ?? ""] })
            } else {
                for r in all { print("\(r)\t\(ExpressVPN.flag(for: r)) \(ExpressVPN.name(of: r))") }
            }
            return 0
        case "connect", "up":
            guard let target = await region() else { return Output.fail("no region matches \(arg); see hop vpn regions") }
            let r = await ExpressVPN.connect(target)
            guard r.ok else { return Output.fail(r.message) }
            let last = await ExpressVPN.waitUntilSettled(true)
            guard last == "Connected" else { return Output.fail("ExpressVPN: \(last.map(ExpressVPN.label(for:)) ?? "unknown")") }
            let name = await ExpressVPN.region().map(ExpressVPN.name(of:))
            print("connected\(name.map { " to \($0)" } ?? "")")
            return 0
        case "disconnect", "down":
            let r = await ExpressVPN.disconnect()
            guard r.ok else { return Output.fail(r.message) }
            let last = await ExpressVPN.waitUntilSettled(false)
            guard last == "Disconnected" else { return Output.fail("ExpressVPN: \(last.map(ExpressVPN.label(for:)) ?? "unknown")") }
            print("disconnected")
            return 0
        case "select":
            guard !arg.isEmpty, let target = await region() ?? nil else { return Output.fail("no region matches \(arg); see hop vpn regions") }
            guard await ExpressVPN.select(target) else { return Output.fail("expressvpnctl could not select \(target)") }
            print("selected \(ExpressVPN.name(of: target))")
            return 0
        default:
            return Output.fail("usage: hop vpn [status] | regions [query] | connect [region] | disconnect | select <region>")
        }
    }
}
