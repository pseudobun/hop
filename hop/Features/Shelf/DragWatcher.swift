import AppKit

/// Recognises a shake: the pointer swinging left and right a few times in quick
/// succession. Only swings of at least `minTravel` points count, so ordinary wobble
/// while dragging does not.
nonisolated struct ShakeDetector: Sendable {
    nonisolated enum Sensitivity: String, Decodable, Equatable, Sendable {
        case low, medium, high

        /// Direction changes needed, the shortest swing that counts and the time they must fit in.
        var parameters: (reversals: Int, minTravel: CGFloat, window: TimeInterval) {
            switch self {
            case .low: (4, 60, 0.7)
            case .medium: (3, 40, 0.65)
            case .high: (2, 28, 0.6)
            }
        }
    }

    var sensitivity: Sensitivity = .medium

    private var anchorX: CGFloat?
    private var direction: CGFloat = 0
    private var reversals: [TimeInterval] = []

    init(sensitivity: Sensitivity = .medium) { self.sensitivity = sensitivity }

    mutating func reset() {
        anchorX = nil
        direction = 0
        reversals = []
    }

    /// Feed one pointer position; true once a shake is complete (and the detector resets).
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        let p = sensitivity.parameters
        guard let anchor = anchorX else {
            anchorX = x
            return false
        }
        let delta = x - anchor
        if direction == 0 {
            // The first swing sets the direction once it is long enough.
            if abs(delta) >= p.minTravel {
                direction = delta > 0 ? 1 : -1
                anchorX = x
            }
            return false
        }
        if delta * direction > 0 {
            anchorX = x // still going the same way: follow the extreme
        } else if abs(delta) >= p.minTravel {
            direction = -direction
            anchorX = x
            reversals.append(time)
            reversals.removeAll { time - $0 > p.window }
            if reversals.count >= p.reversals {
                reset()
                return true
            }
        }
        return false
    }
}

/// Watches system-wide drags (another app's drag session) without Accessibility:
/// global mouse monitors see the pointer, and the drag pasteboard's change count tells
/// a real drag of content apart from moving a window or selecting text.
final class DragWatcher {
    nonisolated struct Config: Equatable {
        var shake = true
        var sensitivity: ShakeDetector.Sensitivity = .medium
        /// Holding exactly these modifiers while dragging opens a shelf; empty is off.
        var modifiers: NSEvent.ModifierFlags = [.shift]
        /// Bundle identifiers whose drags never open a shelf.
        var ignoreApps: Set<String> = []
    }

    /// A shake or the modifier during a drag: open a shelf at this screen point.
    var onActivate: ((NSPoint) -> Void)?
    /// The mouse button went up after a drag of content.
    var onDragEnd: (() -> Void)?

    var config = Config() {
        didSet { shake.sensitivity = config.sensitivity }
    }

    private(set) var isDragging = false
    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var startCount = 0
    private var activated = false
    private var ignored = false
    private var shake = ShakeDetector()

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let add = { (mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] event in self?.dragged(event) }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDragging = false
    }

    private func mouseDown() {
        startCount = dragPasteboard.changeCount
        isDragging = false
        activated = false
        ignored = false
        shake.reset()
    }

    private func dragged(_ event: NSEvent) {
        if !isDragging {
            guard dragPasteboard.changeCount != startCount else { return }
            isDragging = true
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ignored = front.map(config.ignoreApps.contains) ?? false
        }
        guard !activated, !ignored else { return }
        let point = NSEvent.mouseLocation
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let held = !config.modifiers.isEmpty && mods == config.modifiers
        let shook = config.shake && shake.add(x: point.x, time: event.timestamp)
        if held || shook {
            activated = true
            onActivate?(point)
        }
    }

    private func mouseUp() {
        guard isDragging else { return }
        isDragging = false
        onDragEnd?()
    }

    /// `"shift"`, `"alt+shift"`, `""` → modifier flags; nil when a part is unknown.
    static func modifiers(_ text: String) -> NSEvent.ModifierFlags? {
        var flags: NSEvent.ModifierFlags = []
        for part in text.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "shift": flags.insert(.shift)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "opt", "option": flags.insert(.option)
            case "cmd", "command": flags.insert(.command)
            case "", "none", "off": break
            default: return nil
            }
        }
        return flags
    }
}
