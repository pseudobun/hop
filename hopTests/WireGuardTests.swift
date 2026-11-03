import Foundation
import Testing
@testable import hop

struct WireGuardTests {
    static let sample = """
    Available network connection services in the current set (*=enabled):
    * (Connected)      1A2B3C4D-0000-1111-2222-333344445555 VPN (com.wireguard.macos) "si-home"                    [VPN:com.wireguard.macos]
    * (Disconnected)   9F8E7D6C-0000-1111-2222-333344445555 VPN (com.wireguard.macos) "Office"                     [VPN:com.wireguard.macos]
    * (Disconnected)   AAAAAAAA-0000-1111-2222-333344445555 VPN (com.wireguard.macos) "gb09-london"                [VPN:com.wireguard.macos]
    * (Disconnected)   BBBBBBBB-0000-1111-2222-333344445555 IPSec              "Work IPSec"                 [IPSec]
    """

    @Test func parsesAndSorts() {
        let t = WireGuard.parse(Self.sample)
        #expect(t.map(\.name) == ["si-home", "gb09-london", "Office"])
        #expect(t[0].isConnected && t[0].serviceID == "1A2B3C4D-0000-1111-2222-333344445555")
        #expect(t.filter(\.isConnected).count == 1)
    }

    @Test func statusLabels() {
        #expect(WireGuard.label(for: "Connecting") == "Activating…")
        #expect(WireGuard.label(for: "Connected") == "Activated")
        #expect(WireGuard.label(for: "Disconnecting") == "Deactivating…")
        #expect(WireGuard.label(for: "Disconnected") == "Deactivated")
        #expect(WireGuard.isTransitioning("Reasserting") && !WireGuard.isTransitioning("Connected"))
    }

    @Test func flags() {
        #expect(WireGuard.flag(for: "si-home") == "🇸🇮")
        #expect(WireGuard.flag(for: "gb09-london") == "🇬🇧")
        #expect(WireGuard.flag(for: "Office") == "🏴‍☠️")
        #expect(WireGuard.flag(for: "12-x") == "🏴‍☠️")
    }

    @Test func barOrder() {
        let t = WireGuard.parse(Self.sample)
        // Stable by name, not connected-first, so ⌃N keeps meaning the same tunnel.
        #expect(WireGuard.barOrder(t, pinned: []).map(\.name) == ["gb09-london", "Office", "si-home"])
        #expect(WireGuard.barOrder(t, pinned: ["office", "si-home", "missing"]).map(\.name) == ["Office", "si-home"])
    }

    @Test func barConfig() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data("{ wireguard: { bar: false, barTunnels: ['si-home'] } }".utf8))
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.wireguard.bar && template.wireguard.barTunnels.isEmpty)
        #expect(template.wireguard.keys == HopConfig.WireGuard.Keys())
        #expect(template.wireguard.exclusive && HopConfig().wireguard.exclusive)
        let k = try decoder.decode(HopConfig.self, from: Data("{ wireguard: { keys: { focus: 'alt+w', direct: 'alt+cmd' } } }".utf8))
        #expect(k.wireguard.keys.focus == "alt+w" && k.wireguard.keys.direct == "alt+cmd" && k.wireguard.keys.disconnectAll == "cmd+shift+j")
        #expect(HotkeySpec.parse("cmd+j")?.display == "⌘J" && HotkeySpec.parse("alt+cmd+1")?.display == "⌥⌘1")
        #expect(!c.wireguard.bar && c.wireguard.barTunnels == ["si-home"])
        #expect(HopConfig().wireguard.bar && HopConfig().wireguard.barTunnels.isEmpty)
    }
}
