import Foundation

/// The `rings` section: radial menus opened by holding a key, a mouse button or `fn`, or by a
/// trackpad tap. Point at a slice and let go (or click) to run it.
nonisolated extension HopConfig {
    struct Rings: Decodable, Equatable, Sendable {
        nonisolated enum FireOn: String, Decodable, Equatable, Sendable, CaseIterable {
            /// Letting go of the trigger runs the slice pointed at.
            case release
            /// A click runs it; letting go of the trigger closes the ring.
            case click
        }

        nonisolated enum DeadZone: String, Decodable, Equatable, Sendable, CaseIterable {
            case small, standard, large, extraLarge

            /// Radius in points: letting go inside it cancels.
            var radius: Double {
                switch self {
                case .small: 8
                case .standard: 16
                case .large: 22
                case .extraLarge: 28
                }
            }
        }

        var enabled = true
        var fireOn: FireOn = .release
        var deadZone: DeadZone = .standard
        /// Ring size in percent, 60 to 200.
        var size = 100
        /// While a ring is open, 1 to 8 run that slice straight away.
        var digits = true
        /// A soft tick when a slice is pointed at, another when it runs.
        var sounds = false
        /// A haptic tick on a Force Touch trackpad when a slice is pointed at.
        var haptics = true
        /// Count flicks for "Ring Statistics" (kept on this Mac only).
        var statistics = true
        /// One trigger for every app ring: the ring of the app in front opens.
        var appTrigger = ""
        /// Opens the Media ring: play, pause and skip whatever is playing.
        var mediaTrigger = ""
        /// hop's ready app rings (Safari, Chrome, Finder, Xcode, VS Code, Slack, …) on `appTrigger`.
        /// A ring of your own for the same app replaces hop's.
        var builtInAppRings = true
        var rings: [Ring] = []
    }

    struct Ring: Decodable, Equatable, Sendable {
        var name = ""
        /// "hyper+space", "alt+`", "fn", "mouse3" (middle) to "mouse5", "tap3" or "tap4" (trackpad).
        /// Rings on the same trigger: scroll while holding it to switch between them.
        var trigger = ""
        /// A bundle id makes this an app ring: it opens on `rings.appTrigger` while that app is in front.
        var app = ""
        /// The ring stays open after a click or digit runs a slice (let go to close).
        var keepOpen = false
        /// Up to 8; each one is an action string or `{ title, icon, action }` or `{ title, children }`.
        var slices: [Slice] = []
    }

    /// One slice. Written as just its action (`"dark-mode"`, `"key:cmd+t"`) or as an object.
    struct Slice: Decodable, Equatable, Sendable {
        var title = ""
        /// SF Symbol name; empty picks the action's own.
        var icon = ""
        /// See `RingActionRef` for every form; empty with `children` makes a group.
        var action = ""
        /// A group: flick further out past it to reach up to 8 more.
        var children: [Slice] = []

        init(title: String = "", icon: String = "", action: String = "", children: [Slice] = []) {
            self.title = title
            self.icon = icon
            self.action = action
            self.children = children
        }
    }
}

nonisolated extension HopConfig.Rings.FireOn: ConfigChoice {}
nonisolated extension HopConfig.Rings.DeadZone: ConfigChoice {}

nonisolated private extension KeyedDecodingContainer {
    func ringValue<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

nonisolated extension HopConfig.Rings {
    private enum Keys: String, CodingKey {
        case enabled, fireOn, deadZone, size, digits, sounds, haptics, statistics, appTrigger, mediaTrigger, builtInAppRings, rings
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.ringValue(.enabled, d.enabled)
        fireOn = try c.ringValue(.fireOn, d.fireOn)
        deadZone = try c.ringValue(.deadZone, d.deadZone)
        size = try c.ringValue(.size, d.size)
        digits = try c.ringValue(.digits, d.digits)
        sounds = try c.ringValue(.sounds, d.sounds)
        haptics = try c.ringValue(.haptics, d.haptics)
        statistics = try c.ringValue(.statistics, d.statistics)
        appTrigger = try c.ringValue(.appTrigger, d.appTrigger)
        mediaTrigger = try c.ringValue(.mediaTrigger, d.mediaTrigger)
        builtInAppRings = try c.ringValue(.builtInAppRings, d.builtInAppRings)
        rings = try c.ringValue(.rings, d.rings)
    }

    /// `size` as a scale factor, clamped to 0.6…2.
    var scale: Double { min(2, max(0.6, Double(size) / 100)) }
}

nonisolated extension HopConfig.Ring {
    private enum Keys: String, CodingKey { case name, trigger, app, keepOpen, slices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        name = try c.ringValue(.name, d.name)
        trigger = try c.ringValue(.trigger, d.trigger)
        app = try c.ringValue(.app, d.app)
        keepOpen = try c.ringValue(.keepOpen, d.keepOpen)
        slices = try c.ringValue(.slices, d.slices)
    }
}

nonisolated extension HopConfig.Slice {
    private enum Keys: String, CodingKey { case title, icon, action, children }
    init(from decoder: Decoder) throws {
        if let action = try? decoder.singleValueContainer().decode(String.self) {
            self.init(action: action)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(title: try c.ringValue(.title, ""), icon: try c.ringValue(.icon, ""),
                  action: try c.ringValue(.action, ""), children: try c.ringValue(.children, []))
    }
}
