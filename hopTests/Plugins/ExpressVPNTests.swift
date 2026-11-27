import Foundation
import Testing
@testable import hop

struct ExpressVPNTests {
    static let regions = ExpressVPN.parseRegions("smart\nslovenia\nuk-london\nusa-new-york\nusa-st.-louis\n\nindia-(via-uk)\n  bosnia-and-herzegovina \ngaming-europe\nhong-kong-2\nnetherlands-the-hague\n")

    @Test func parsesRegions() {
        #expect(Self.regions.count == 10)
        #expect(Self.regions.first == "smart" && Self.regions.contains("bosnia-and-herzegovina"))
    }

    @Test func names() {
        #expect(ExpressVPN.name(of: "usa-new-york") == "USA New York")
        #expect(ExpressVPN.name(of: "uk-london") == "UK London")
        #expect(ExpressVPN.name(of: "india-(via-uk)") == "India (via UK)")
        #expect(ExpressVPN.name(of: "usa-st.-louis") == "USA St. Louis")
        #expect(ExpressVPN.name(of: "bosnia-and-herzegovina") == "Bosnia and Herzegovina")
        #expect(ExpressVPN.name(of: "germany-frankfurt-3") == "Germany Frankfurt 3")
        #expect(ExpressVPN.name(of: "smart") == "Smart Location")
    }

    @Test func flags() {
        #expect(ExpressVPN.flag(for: "slovenia") == "🇸🇮")
        #expect(ExpressVPN.flag(for: "uk-london") == "🇬🇧")
        #expect(ExpressVPN.flag(for: "usa-new-york") == "🇺🇸")
        #expect(ExpressVPN.flag(for: "hong-kong-2") == "🇭🇰")
        #expect(ExpressVPN.flag(for: "south-korea-2") == "🇰🇷")
        #expect(ExpressVPN.flag(for: "india-(via-uk)") == "🇮🇳")
        #expect(ExpressVPN.flag(for: "smart") == "⚡️" && ExpressVPN.flag(for: "gaming-europe") == "🎮")
        #expect(ExpressVPN.flag(for: "atlantis") == "🌐")
        // "uk" must not match "ukraine".
        #expect(ExpressVPN.country(of: "ukraine") == "UA")
    }

    @Test func resolves() {
        let r = Self.regions
        #expect(ExpressVPN.resolve("slovenia", in: r) == "slovenia")
        #expect(ExpressVPN.resolve("UK London", in: r) == "uk-london")
        #expect(ExpressVPN.resolve("usa", in: r) == "usa-new-york")
        #expect(ExpressVPN.resolve("hong kong", in: r) == "hong-kong-2")
        #expect(ExpressVPN.resolve("mars", in: r) == nil && ExpressVPN.resolve(" ", in: r) == nil)
    }

    @Test func favoritesKeepConfigOrder() {
        let f = ExpressVPN.favorites(["uk london", "slovenia", "missing", "slovenia"], in: Self.regions)
        #expect(f == ["uk-london", "slovenia"])
    }

    @Test func states() {
        #expect(ExpressVPN.isConnected("Connected") && !ExpressVPN.isConnected("Connecting"))
        #expect(ExpressVPN.isTransitioning("DisconnectingToReconnect") && !ExpressVPN.isTransitioning("Disconnected"))
        #expect(ExpressVPN.label(for: "Reconnecting") == "Reconnecting…")
    }

    @Test func config() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.expressvpn == HopConfig.ExpressVPN())
        let c = try decoder.decode(HopConfig.self, from: Data("{ expressvpn: { showFlags: false, favorites: ['slovenia'] } }".utf8))
        #expect(!c.expressvpn.showFlags && c.expressvpn.favorites == ["slovenia"])
    }
}
