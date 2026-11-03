import AppKit
import Carbon.HIToolbox

/// A row under the root search field that the launcher shows when it has something in it.
protocol LauncherStrip: NSView {
    /// Hidden while false (nothing to show, or the feature is off).
    var hasContent: Bool { get }
    /// Keys go to the strip (a selector in it) instead of the results.
    var isFocused: Bool { get }
    /// What ↵ does to the selected element while focused, for the footer.
    var focusedActionTitle: String? { get }
    /// Called when `hasContent` or `isFocused` changes, so the launcher can update the row and footer.
    var onContentChange: (() -> Void)? { get set }
    /// Keys the strip owns while the root search is in front; true consumes the event.
    func handle(_ event: NSEvent) -> Bool
    func launcherDidShow()
    func launcherDidHide()
}

extension HotkeySpec {
    /// Same key (by key code, so any keyboard layout) and exactly the same modifiers.
    func matches(_ event: NSEvent) -> Bool {
        var mods: UInt32 = 0
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return UInt32(event.keyCode) == keyCode && mods == modifiers
    }

    /// "⌃⌥⇧⌘J" for a keycap.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let name = Self.keyCodes.first { $0.value == Int(keyCode) && $0.key != "enter" }?.key ?? "?"
        return s + (name.count == 1 ? name.uppercased() : name.capitalized)
    }
}

nonisolated extension WireGuard {
    /// Bar order: `pinned` names first in their order (only those, when any are given),
    /// otherwise every tunnel by name. Stable, so ⌃1…⌃9 always mean the same tunnel.
    static func barOrder(_ tunnels: [WireGuardTunnel], pinned: [String]) -> [WireGuardTunnel] {
        if !pinned.isEmpty {
            return pinned.compactMap { name in
                tunnels.first { $0.name == name } ?? tunnels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
        return tunnels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Tunnels as pills under the search field: status at a glance, click to toggle, or
/// `wireguard.keys.focus` to select one with ←→ and toggle it with ↵.
/// Polls `scutil --nc list` only while the launcher is open.
final class WireGuardBar: NSView, LauncherStrip {
    var onContentChange: (() -> Void)?
    /// Opens the full tunnel list (the "+N" pill).
    var onShowAll: (() -> Void)?
    var config: () -> HopConfig.WireGuard = { HopConfig.WireGuard() }

    private(set) var hasContent = false {
        didSet { if hasContent != oldValue { onContentChange?() } }
    }

    /// Selected pill while the bar has the keys; nil when the search field has them.
    private var selected: Int? {
        didSet {
            guard selected != oldValue else { return }
            updateSelection()
            onContentChange?()
        }
    }

    var isFocused: Bool { selected != nil }

    var focusedActionTitle: String? {
        guard let i = selected, i < tunnels.count else { return nil }
        let t = tunnels[i]
        return t.isTransitioning ? nil : t.isConnected ? "Deactivate \(t.name)" : "Activate \(t.name)"
    }

    private var keys: HopConfig.WireGuard.Keys { config().keys }

    private var tunnels: [WireGuardTunnel] = []
    /// Tunnels being started or stopped from here: polling leaves their state alone.
    private var tracking: Set<String> = []
    private var poll: Task<Void, Never>?
    private let icon = NSImageView()
    private let stack = NSStackView()
    private let more = WireGuardPill()
    private let hint = NSTextField(labelWithString: "")
    private var pills: [WireGuardPill] = []
    private var fittedWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "WireGuard")
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.detachesHiddenViews = true
        more.onClick = { [weak self] in self?.onShowAll?() }
        hint.font = Theme.mono(10, 500)
        hint.textColor = Theme.mutedForeground
        for v in [icon, stack, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - LauncherStrip

    func launcherDidShow() {
        guard config().enabled && config().bar else {
            stop()
            show([])
            return
        }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let list = await WireGuard.list()
                guard !Task.isCancelled else { return }
                self?.merge(list)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func launcherDidHide() {
        stop()
        selected = nil
    }

    private func stop() {
        poll?.cancel()
        poll = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard hasContent else { return false }
        let keys = keys
        if let spec = HotkeySpec.parse(keys.focus), spec.matches(event) {
            selected = selected == nil ? firstSelection : nil
            return true
        }
        if let spec = HotkeySpec.parse(keys.disconnectAll), spec.matches(event) {
            disconnectAll()
            return true
        }
        if !keys.direct.isEmpty {
            for n in 1...min(9, tunnels.count) {
                if let spec = HotkeySpec.parse("\(keys.direct)+\(n)"), spec.matches(event) {
                    toggle(tunnels[n - 1])
                    return true
                }
            }
        }
        guard let i = selected else { return false }
        let bare = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        let shift = event.modifierFlags.intersection(KeyCombo.relevant) == .shift
        switch event.keyCode {
        case 123 where bare, 48 where shift: selected = step(from: i, by: -1) // ←, ⇧Tab
        case 124 where bare, 48 where bare: selected = step(from: i, by: 1) // →, Tab
        case 36 where bare, 76 where bare, 49 where bare: // ↵, Space
            if i < tunnels.count { toggle(tunnels[i]) } else { onShowAll?() }
        case 53, 125, 126: selected = nil // Esc, ↓, ↑: back to the results
        default:
            // Anything else is typing: hand the keys back to the search field.
            selected = nil
            return false
        }
        return true
    }

    /// Visible pills (and "+N") in order, as indices into `tunnels`; `tunnels.count` is "+N".
    private var selectable: [Int] {
        pills.indices.filter { !pills[$0].isHidden } + (more.isHidden ? [] : [tunnels.count])
    }

    /// The active tunnel, else the first.
    private var firstSelection: Int? {
        let s = selectable
        return s.first { $0 < tunnels.count && tunnels[$0].isConnected } ?? s.first
    }

    private func step(from i: Int, by d: Int) -> Int {
        let s = selectable
        guard let at = s.firstIndex(of: i) else { return s.first ?? i }
        return s[(at + d + s.count) % s.count]
    }

    #if DEBUG
    func debugFocus() { selected = firstSelection }
    #endif

    private func disconnectAll() {
        for t in tunnels where t.isConnected && !tracking.contains(t.serviceID) { toggle(t) }
    }

    // MARK: - State

    private func merge(_ list: [WireGuardTunnel]) {
        let fresh = list.map { t in tracking.contains(t.serviceID) ? tunnels.first { $0.serviceID == t.serviceID } ?? t : t }
        show(WireGuard.barOrder(fresh, pinned: config().barTunnels))
    }

    private func show(_ list: [WireGuardTunnel]) {
        if list != tunnels || stack.arrangedSubviews.isEmpty != list.isEmpty { tunnels = list; rebuild() }
        hasContent = !tunnels.isEmpty
    }

    private func setStatus(_ status: String, of t: WireGuardTunnel) {
        guard let i = tunnels.firstIndex(where: { $0.serviceID == t.serviceID }) else { return }
        tunnels[i] = WireGuardTunnel(name: t.name, serviceID: t.serviceID, isConnected: status == "Connected", status: status)
        rebuild()
    }

    private func toggle(_ t: WireGuardTunnel) {
        guard let current = tunnels.first(where: { $0.serviceID == t.serviceID }), !current.isTransitioning else { return }
        let on = !current.isConnected
        tracking.insert(t.serviceID)
        setStatus(on ? "Connecting" : "Disconnecting", of: t)
        Task {
            defer { tracking.remove(t.serviceID) }
            guard await WireGuard.setConnected(t, on) else {
                HUD.shared.fail("scutil could not \(on ? "start" : "stop") \(t.name)")
                setStatus(on ? "Disconnected" : "Connected", of: t)
                return
            }
            let target = on ? "Connected" : "Disconnected"
            let last = await WireGuard.waitUntilSettled(t, on) { [weak self] s in
                if WireGuard.isTransitioning(s) || s == target { self?.setStatus(s, of: t) }
            }
            if let last { setStatus(last, of: t) }
            if last != target { HUD.shared.warn("\(t.name) did not \(on ? "activate" : "deactivate")") }
        }
    }

    // MARK: - Views

    private func rebuild() {
        let showFlags = config().showFlags
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pills = []
        for (i, t) in tunnels.enumerated() {
            let pill = WireGuardPill()
            let direct = keys.direct.isEmpty || i >= 9 ? nil : HotkeySpec.parse("\(keys.direct)+\(i + 1)")?.display
            pill.configure(title: showFlags ? "\(t.flag) \(t.name)" : t.name,
                           state: t.isTransitioning ? .busy : t.isConnected ? .on : .off,
                           key: direct, status: true)
            pill.toolTip = "\(t.name): \(t.label)"
            pill.onClick = { [weak self] in self?.toggle(t) }
            stack.addArrangedSubview(pill)
            pills.append(pill)
        }
        more.configure(title: "+0", state: .off, key: nil, status: false)
        more.toolTip = "All WireGuard tunnels"
        stack.addArrangedSubview(more)
        hint.stringValue = HotkeySpec.parse(keys.focus)?.display ?? ""
        fittedWidth = -1
        needsLayout = true
        let anyOn = tunnels.contains { $0.isConnected }
        let anyBusy = tunnels.contains { $0.isTransitioning }
        icon.contentTintColor = anyBusy ? Theme.warn : anyOn ? Theme.good : Theme.mutedForeground
    }

    override func layout() {
        super.layout()
        if bounds.width != fittedWidth { fit() }
    }

    /// Shows the pills that fit: active tunnels always, then the rest in order, "+N" for what is left.
    private func fit() {
        fittedWidth = bounds.width
        // Leading inset, icon, gap; trailing inset.
        let available = bounds.width - (22 + icon.fittingSize.width + 10) - 18 - (hint.stringValue.isEmpty ? 0 : hint.fittingSize.width + 12)
        let gap = stack.spacing
        let widths = pills.map(\.fittingSize.width)
        var shown = Set(tunnels.indices.filter { tunnels[$0].isConnected || tunnels[$0].isTransitioning })
        var used = shown.reduce(0) { $0 + widths[$1] + gap }
        more.configure(title: "+\(pills.count)", state: .off, key: nil, status: false)
        let moreWidth = more.fittingSize.width + gap
        let all = widths.reduce(0) { $0 + $1 + gap }
        // In order, stopping at the first that does not fit, with room left for "+N".
        for i in pills.indices where !shown.contains(i) {
            guard used + widths[i] + gap + (all <= available ? 0 : moreWidth) <= available else { break }
            shown.insert(i)
            used += widths[i] + gap
        }
        for (i, pill) in pills.enumerated() { pill.isHidden = !shown.contains(i) }
        let hidden = pills.count - shown.count
        more.configure(title: "+\(hidden)", state: .off, key: nil, status: false)
        more.isHidden = hidden == 0
        if let i = selected, !selectable.contains(i) { selected = firstSelection }
        updateSelection()
    }

    private func updateSelection() {
        for (i, pill) in pills.enumerated() { pill.isSelected = selected == i }
        more.isSelected = selected == tunnels.count
        hint.textColor = selected == nil ? Theme.mutedForeground : Theme.info
    }

}

/// One tunnel: status dot, name, and its ⌃N key.
final class WireGuardPill: NSView {
    enum State { case on, off, busy }

    var onClick: (() -> Void)?
    private(set) var title = ""
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private var state = State.off
    private var tone = Theme.mutedForeground

    /// Keyboard selection in the bar: an info-coloured ring.
    var isSelected = false {
        didSet { if isSelected != oldValue { applyColors() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        label.font = Theme.sans(12, 500)
        label.lineBreakMode = .byTruncatingTail
        keyLabel.font = Theme.mono(10, 500)
        keyLabel.textColor = Theme.mutedForeground
        let row = NSStackView(views: [dot, label, keyLabel])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, state: State, key: String?, status: Bool) {
        self.title = title
        self.state = state
        label.stringValue = title
        keyLabel.stringValue = key ?? ""
        keyLabel.isHidden = key == nil
        tone = switch state {
        case .on: Theme.good
        case .busy: Theme.warn
        case .off: Theme.mutedForeground
        }
        dot.isHidden = !status // the "+N" pill has no status
        dot.layer?.backgroundColor = (state == .off ? Theme.mutedForeground.withAlphaComponent(0.5) : tone).cgColor
        applyColors()
        dot.layer?.removeAnimation(forKey: "pulse")
        if state == .busy {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    private func applyColors() {
        label.textColor = state == .off && !isSelected ? Theme.mutedForeground : Theme.foreground
        layer?.backgroundColor = (state == .off ? Theme.foreground.withAlphaComponent(isSelected ? 0.10 : 0.05)
            : tone.withAlphaComponent(isSelected ? 0.22 : 0.14)).cgColor
        layer?.borderColor = (isSelected ? Theme.info : state == .off ? Theme.border : tone.withAlphaComponent(0.35)).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 0.5
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
