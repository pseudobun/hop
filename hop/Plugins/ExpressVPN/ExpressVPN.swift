import AppKit

/// ExpressVPN through its own CLI, `expressvpnctl` (shipped with ExpressVPN.app, linked into
/// /usr/local/bin). `connect` needs the app running, or `expressvpnctl background enable`.
nonisolated enum ExpressVPN {
    static var executable: String? {
        ["/usr/local/bin/expressvpnctl", "/opt/homebrew/bin/expressvpnctl", "/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The region `connect` without an argument uses.
    static let smart = "smart"

    // MARK: States (`expressvpnctl get connectionstate`)

    static func isConnected(_ state: String) -> Bool { state == "Connected" }

    static func isTransitioning(_ state: String) -> Bool {
        ["Connecting", "Reconnecting", "DisconnectingToReconnect", "Disconnecting", "Interrupted"].contains(state)
    }

    static func label(for state: String) -> String {
        switch state {
        case "Connecting": "Connecting…"
        case "Reconnecting", "DisconnectingToReconnect": "Reconnecting…"
        case "Disconnecting": "Disconnecting…"
        default: state
        }
    }

    // MARK: Regions

    /// One region per line; blank lines and stray whitespace dropped.
    static func parseRegions(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "usa-new-york" → "USA New York", "india-(via-uk)" → "India (via UK)", "smart" → "Smart Location".
    static func name(of region: String) -> String {
        if region == smart { return "Smart Location" }
        let upper: Set<String> = ["usa", "uk", "dc", "cbd"]
        let lower: Set<String> = ["and", "of", "via"]
        return region.split(separator: "-").enumerated().map { i, raw in
            let word = String(raw)
            let open = word.hasPrefix("("), close = word.hasSuffix(")")
            let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            var out = upper.contains(core) ? core.uppercased()
                : (i > 0 && lower.contains(core)) ? core
                : core.prefix(1).uppercased() + core.dropFirst()
            if open { out = "(" + out }
            if close { out += ")" }
            return out
        }
        .joined(separator: " ")
    }

    /// Country slugs of ExpressVPN's region names → ISO 3166 codes.
    static let countries: [String: String] = [
        "albania": "AL", "algeria": "DZ", "andorra": "AD", "argentina": "AR", "armenia": "AM", "australia": "AU",
        "austria": "AT", "azerbaijan": "AZ", "bahamas": "BS", "bangladesh": "BD", "belarus": "BY", "belgium": "BE",
        "bermuda": "BM", "bhutan": "BT", "bolivia": "BO", "bosnia-and-herzegovina": "BA", "brazil": "BR", "brunei": "BN",
        "bulgaria": "BG", "cambodia": "KH", "canada": "CA", "cayman-islands": "KY", "chile": "CL", "china": "CN",
        "colombia": "CO", "costa-rica": "CR", "croatia": "HR", "cuba": "CU", "cyprus": "CY", "czech-republic": "CZ",
        "denmark": "DK", "dominican-republic": "DO", "ecuador": "EC", "egypt": "EG", "estonia": "EE", "finland": "FI",
        "france": "FR", "georgia": "GE", "germany": "DE", "ghana": "GH", "greece": "GR", "greenland": "GL", "guam": "GU",
        "guatemala": "GT", "honduras": "HN", "hong-kong": "HK", "hungary": "HU", "iceland": "IS", "india": "IN",
        "indonesia": "ID", "ireland": "IE", "isle-of-man": "IM", "israel": "IL", "italy": "IT", "jamaica": "JM",
        "japan": "JP", "jersey": "JE", "kazakhstan": "KZ", "kenya": "KE", "laos": "LA", "latvia": "LV", "lebanon": "LB",
        "liechtenstein": "LI", "lithuania": "LT", "luxembourg": "LU", "macau": "MO", "malaysia": "MY", "malta": "MT",
        "mexico": "MX", "moldova": "MD", "monaco": "MC", "mongolia": "MN", "montenegro": "ME", "morocco": "MA",
        "myanmar": "MM", "nepal": "NP", "netherlands": "NL", "new-zealand": "NZ", "nigeria": "NG",
        "north-macedonia": "MK", "norway": "NO", "pakistan": "PK", "panama": "PA", "peru": "PE", "philippines": "PH",
        "poland": "PL", "portugal": "PT", "puerto-rico": "PR", "qatar": "QA", "romania": "RO", "saudi-arabia": "SA",
        "serbia": "RS", "singapore": "SG", "slovakia": "SK", "slovenia": "SI", "south-africa": "ZA", "south-korea": "KR",
        "spain": "ES", "sri-lanka": "LK", "sweden": "SE", "switzerland": "CH", "taiwan": "TW", "thailand": "TH",
        "trinidad-and-tobago": "TT", "turkey": "TR", "uk": "GB", "ukraine": "UA", "united-arab-emirates": "AE",
        "uruguay": "UY", "usa": "US", "uzbekistan": "UZ", "venezuela": "VE", "vietnam": "VN",
    ]

    private static let countriesByLength = countries.keys.sorted { $0.count > $1.count }

    /// ISO code of a region's country: the longest country slug it starts with.
    static func country(of region: String) -> String? {
        countriesByLength.first { region == $0 || region.hasPrefix($0 + "-") }.flatMap { countries[$0] }
    }

    static func flag(for region: String) -> String {
        if region == smart { return "⚡️" }
        if region.hasPrefix("gaming-") { return "🎮" }
        guard let code = country(of: region) else { return "🌐" }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1A5 + $0.value) }))
    }

    /// A region from what someone typed: its slug, its name, or the first one either starts with.
    static func resolve(_ query: String, in regions: [String]) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let slug = q.replacingOccurrences(of: " ", with: "-")
        return regions.first { $0 == slug || name(of: $0).lowercased() == q }
            ?? regions.first { $0.hasPrefix(slug) || name(of: $0).lowercased().hasPrefix(q) }
    }

    /// Favourites as the config lists them (slugs or names), resolved and in that order.
    static func favorites(_ names: [String], in regions: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { n in
            let q = n.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
            return regions.first { $0 == q || name(of: $0).lowercased().replacingOccurrences(of: " ", with: "-") == q }
        }
        .filter { seen.insert($0).inserted }
    }

    // MARK: expressvpnctl

    static func run(_ args: [String], timeout: Duration = .seconds(10)) async -> ProcessResult? {
        guard let exe = executable else { return nil }
        return try? await ProcessRunner.run(exe, args, timeout: timeout)
    }

    /// The first line of `expressvpnctl get <type>`.
    static func get(_ type: String) async -> String? {
        guard let r = await run(["get", type]), r.ok,
              let first = r.out.split(whereSeparator: \.isNewline).first else { return nil }
        let value = first.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func state() async -> String? { await get("connectionstate") }
    static func region() async -> String? { await get("region") }

    static func regions() async -> [String] {
        guard let r = await run(["get", "regions"]), r.ok else { return [] }
        return parseRegions(r.out)
    }

    /// The VPN's address while connected; nil (expressvpnctl says "Unknown") otherwise.
    static func vpnIP() async -> String? {
        guard let ip = await get("vpnip"), ip != "Unknown" else { return nil }
        return ip
    }

    /// What went wrong, from expressvpnctl's own words.
    static func failure(_ r: ProcessResult?, _ fallback: String) -> String {
        guard let r else { return executable == nil ? "expressvpnctl not found" : fallback }
        let text = (r.err + "\n" + r.out).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return text ?? fallback
    }

    /// Connects to `region` (nil: the selected one); also reconnects to switch regions.
    static func connect(_ region: String? = nil) async -> (ok: Bool, message: String) {
        let r = await run(["connect"] + (region.map { [$0] } ?? []), timeout: .seconds(45))
        return r?.ok == true ? (true, "") : (false, failure(r, "ExpressVPN could not connect"))
    }

    static func disconnect() async -> (ok: Bool, message: String) {
        let r = await run(["disconnect"], timeout: .seconds(20))
        return r?.ok == true ? (true, "") : (false, failure(r, "ExpressVPN could not disconnect"))
    }

    /// Makes `region` the one `connect` uses, without connecting.
    static func select(_ region: String) async -> Bool {
        await run(["set", "region", region])?.ok == true
    }

    /// Polls until the connection reaches `on`, settles elsewhere or `timeout` passes. Calls
    /// `progress` with each state seen; returns the last one.
    static func waitUntilSettled(_ on: Bool, timeout: Duration = .seconds(30),
                                 progress: (String) async -> Void = { _ in }) async -> String? {
        let start = ContinuousClock.now
        let target = on ? "Connected" : "Disconnected"
        var last: String?
        while ContinuousClock.now - start < timeout {
            if let s = await state() {
                if s != last { await progress(s) }
                last = s
                if s == target || (!isTransitioning(s) && ContinuousClock.now - start > .seconds(3)) { break }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return last
    }
}

/// Sub-mode: the connection on top, then favourites and every region; ↵ connects.
final class ExpressVPNMode: Mode {
    let title: String? = "ExpressVPN"
    let tint: NSColor? = Palette.expressvpn
    let placeholder = "Search regions…"
    private let showFlags: Bool
    private let favoriteNames: [String]
    private let sensitivity: Sensitivity
    private var state: String?
    private var selected: String?
    private var ip: String?
    private var regions: [String] = []
    private var loaded = false
    private var busy = false
    private weak var context: LauncherContext?

    init(showFlags: Bool, favorites: [String], sensitivity: Sensitivity) {
        self.showFlags = showFlags
        self.favoriteNames = favorites
        self.sensitivity = sensitivity
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        refresh()
    }

    private func refresh() {
        Task {
            context?.setLoading(true)
            async let s = ExpressVPN.state(), r = ExpressVPN.region(), all = ExpressVPN.regions(), v = ExpressVPN.vpnIP()
            (state, selected, regions, ip) = await (s, r, all, v)
            loaded = true
            context?.setLoading(false)
            context?.reload()
        }
    }

    /// Connects (or disconnects) and shows the state on the rows until it settles.
    private func change(_ on: Bool, to region: String? = nil) {
        busy = true
        state = on ? "Connecting" : "Disconnecting"
        if let region { selected = region }
        context?.reload()
        Task {
            let r = on ? await ExpressVPN.connect(region) : await ExpressVPN.disconnect()
            guard r.ok else {
                busy = false
                refresh()
                context?.showHUD(r.message)
                return
            }
            let last = await ExpressVPN.waitUntilSettled(on) { [weak self] s in
                self?.state = s
                self?.context?.reload()
            }
            busy = false
            refresh()
            let where_ = selected.map { " to \(ExpressVPN.name(of: $0))" } ?? ""
            switch last {
            case "Connected" where on: context?.showHUD("Connected\(where_)")
            case "Disconnected" where !on: context?.showHUD("ExpressVPN disconnected")
            case let s? where ExpressVPN.isTransitioning(s): context?.showHUD("ExpressVPN is still \(ExpressVPN.label(for: s).lowercased())")
            default: context?.showHUD(on ? "ExpressVPN did not connect" : "ExpressVPN did not disconnect")
            }
        }
    }

    private func statusItem() -> Item {
        let s = state ?? "Unknown"
        let on = ExpressVPN.isConnected(s), moving = busy || ExpressVPN.isTransitioning(s)
        let region = selected.map(ExpressVPN.name(of:))
        var subtitle = [region, on ? ip : nil].compactMap { $0 }.joined(separator: " · ")
        if state == nil { subtitle = "expressvpnctl did not answer; is ExpressVPN running?" }
        let action: Action? = moving ? nil
            : on ? Action(title: "Disconnect", style: .destructive) { [weak self] in self?.change(false); return .stay }
            : Action(title: region.map { "Connect to \($0)" } ?? "Connect") { [weak self] in self?.change(true); return .stay }
        return Item(id: "expressvpn.status", title: "ExpressVPN", subtitle: subtitle.isEmpty ? nil : subtitle,
                    icon: .tile(moving ? "shield.lefthalf.filled" : on ? "lock.shield.fill" : "shield.slash.fill",
                                moving ? Theme.warn : on ? Theme.good : Palette.neutral),
                    actions: action.map { [$0] } ?? [], tracksFrecency: false,
                    chip: Chip(text: ExpressVPN.label(for: s), tone: moving ? .warn : on ? .good : .neutral))
    }

    private func item(_ region: String) -> Item {
        let s = state ?? ""
        let isSelected = region == selected
        let chip: Chip? = !isSelected ? nil
            : ExpressVPN.isConnected(s) ? Chip(text: "Connected", tone: .good)
            : (busy || ExpressVPN.isTransitioning(s)) ? Chip(text: ExpressVPN.label(for: s), tone: .warn) : nil
        let connected = isSelected && ExpressVPN.isConnected(s)
        var actions: [Action] = []
        if !busy {
            actions.append(connected
                ? Action(title: "Disconnect", style: .destructive) { [weak self] in self?.change(false); return .stay }
                : Action(title: "Connect") { [weak self] in self?.change(true, to: region); return .stay })
            if !isSelected {
                actions.append(Action(title: "Select Without Connecting", symbol: "checkmark.circle") { [weak self] in
                    guard await ExpressVPN.select(region) else { return .failWithHUD("expressvpnctl could not select \(region)") }
                    self?.selected = region
                    return .reload
                })
            }
        }
        let name = ExpressVPN.name(of: region)
        let slugDiffers = region != name.lowercased().replacingOccurrences(of: " ", with: "-")
        return Item(id: "expressvpn.region." + region, title: name, subtitle: slugDiffers ? region : nil,
                    icon: showFlags ? .emoji(ExpressVPN.flag(for: region)) : .tile("globe", Palette.neutral),
                    accessory: isSelected && chip == nil ? "Selected" : nil,
                    actions: actions, tracksFrecency: false, chip: chip)
    }

    func sections(for query: String) -> [ResultSection] {
        if loaded && ExpressVPN.executable == nil {
            return [ResultSection(title: nil, items: [Item(
                id: "expressvpn.none", title: "ExpressVPN is not installed", subtitle: "expressvpnctl comes with ExpressVPN.app",
                icon: .symbol("exclamationmark.triangle"), actions: [], tracksFrecency: false)])]
        }
        guard loaded else { return [] }
        if !query.isEmpty {
            let cands = regions.map { RankCandidate(id: $0, title: ExpressVPN.name(of: $0), typeWeight: 1) }
            let hits = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { regions[$0] }
            return [ResultSection(title: "Regions", items: hits.map(item))]
        }
        let favorites = ExpressVPN.favorites(favoriteNames, in: regions)
        var out = [ResultSection(title: nil, items: [statusItem()])]
        if !favorites.isEmpty { out.append(ResultSection(title: "Favorites", items: favorites.map(item))) }
        let fav = Set(favorites)
        out.append(ResultSection(title: "Regions", items: regions.filter { !fav.contains($0) }.map(item)))
        return out
    }
}

enum ExpressVPNCommands {
    static func items(_ services: Services) -> [Item] {
        guard ExpressVPN.executable != nil else { return [] }
        let config = services.settings.data
        let tile = ItemIcon.tile("lock.shield.fill", Palette.expressvpn)
        return [
            Item(id: "expressvpn.regions", title: "ExpressVPN", subtitle: "Connect, disconnect or pick a region",
                 aliases: ["vpn", "express vpn"], icon: tile, accessory: "Command",
                 actions: [Action(title: "Show Regions") {
                     .push(ExpressVPNMode(showFlags: config.expressvpn.showFlags, favorites: config.expressvpn.favorites,
                                          sensitivity: config.general.sensitivity))
                 }], pushesMode: true),
            Item(id: "expressvpn.connect", title: "Connect ExpressVPN", subtitle: "To the selected region",
                 aliases: ["vpn on"], icon: tile, accessory: "Command",
                 actions: [Action(title: "Connect") {
                     let r = await ExpressVPN.connect()
                     guard r.ok else { return .failWithHUD(r.message) }
                     let region = await ExpressVPN.region().map(ExpressVPN.name(of:))
                     return .dismissWithHUD(region.map { "ExpressVPN: \($0)" } ?? "ExpressVPN connecting…")
                 }]),
            Item(id: "expressvpn.disconnect", title: "Disconnect ExpressVPN",
                 aliases: ["vpn off"], icon: .tile("shield.slash.fill", Palette.expressvpn), accessory: "Command",
                 actions: [Action(title: "Disconnect") {
                     let r = await ExpressVPN.disconnect()
                     return r.ok ? .dismissWithHUD("ExpressVPN disconnected") : .failWithHUD(r.message)
                 }]),
        ]
    }
}
