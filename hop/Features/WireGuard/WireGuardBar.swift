import AppKit

/// A row under the root search field that the launcher shows when it has something in it.
protocol LauncherStrip: NSView {
    /// Hidden while false (nothing to show, or the feature is off).
    var hasContent: Bool { get }
    /// Called when `hasContent` changes, so the launcher can collapse or expand the row.
    var onContentChange: (() -> Void)? { get set }
    /// Keys the strip owns while the root search is in front; true consumes the event.
    func handle(_ event: NSEvent) -> Bool
    func launcherDidShow()
    func launcherDidHide()
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

/// Tunnels as pills under the search field: status at a glance, click or ⌃1…⌃9 to toggle.
/// Polls `scutil --nc list` only while the launcher is open.
final class WireGuardBar: NSView, LauncherStrip {
    var onContentChange: (() -> Void)?
    /// Opens the full tunnel list (the "+N" pill).
    var onShowAll: (() -> Void)?
    var config: () -> HopConfig.WireGuard = { HopConfig.WireGuard() }

    private(set) var hasContent = false {
        didSet { if hasContent != oldValue { onContentChange?() } }
    }

    private var tunnels: [WireGuardTunnel] = []
    /// Tunnels being started or stopped from here: polling leaves their state alone.
    private var tracking: Set<String> = []
    private var poll: Task<Void, Never>?
    private let icon = NSImageView()
    private let stack = NSStackView()
    private let more = WireGuardPill()
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
        for v in [icon, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    func launcherDidHide() { stop() }

    private func stop() {
        poll?.cancel()
        poll = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard hasContent, event.modifierFlags.intersection(KeyCombo.relevant) == .control,
              let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n), n <= tunnels.count
        else { return false }
        toggle(tunnels[n - 1])
        return true
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
            pill.configure(title: showFlags ? "\(t.flag) \(t.name)" : t.name,
                           state: t.isTransitioning ? .busy : t.isConnected ? .on : .off,
                           key: i < 9 ? "⌃\(i + 1)" : nil)
            pill.toolTip = "\(t.name): \(t.label)"
            pill.onClick = { [weak self] in self?.toggle(t) }
            stack.addArrangedSubview(pill)
            pills.append(pill)
        }
        more.configure(title: "+0", state: .off, key: nil)
        more.toolTip = "All WireGuard tunnels"
        stack.addArrangedSubview(more)
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
        let available = bounds.width - (22 + icon.fittingSize.width + 10) - 18
        let gap = stack.spacing
        let widths = pills.map(\.fittingSize.width)
        var shown = Set(tunnels.indices.filter { tunnels[$0].isConnected || tunnels[$0].isTransitioning })
        var used = shown.reduce(0) { $0 + widths[$1] + gap }
        more.configure(title: "+\(pills.count)", state: .off, key: nil)
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
        more.configure(title: "+\(hidden)", state: .off, key: nil)
        more.isHidden = hidden == 0
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

    func configure(title: String, state: State, key: String?) {
        self.title = title
        self.state = state
        label.stringValue = title
        keyLabel.stringValue = key ?? ""
        keyLabel.isHidden = key == nil
        let tone: NSColor = switch state {
        case .on: Theme.good
        case .busy: Theme.warn
        case .off: Theme.mutedForeground
        }
        dot.isHidden = key == nil // the "+N" pill has no status
        dot.layer?.backgroundColor = (state == .off ? Theme.mutedForeground.withAlphaComponent(0.5) : tone).cgColor
        label.textColor = state == .off ? Theme.mutedForeground : Theme.foreground
        layer?.backgroundColor = (state == .off ? Theme.foreground.withAlphaComponent(0.05) : tone.withAlphaComponent(0.14)).cgColor
        layer?.borderColor = (state == .off ? Theme.border : tone.withAlphaComponent(0.35)).cgColor
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

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
