import AppKit

/// Rounded selection like Raycast, drawn on top of glass.
final class ResultRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultRow")

    var tint: NSColor? {
        didSet { if tint != oldValue && isSelected { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        let tone = tint ?? Theme.info
        tone.withAlphaComponent(0.14).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.fill()
        tone.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

final class ResultCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    /// Pill behind `chipLabel`; a bare NSTextField draws its text at the top of a taller frame.
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    /// Dock-style "app is open" dot under the icon.
    private let runningDot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = Theme.body
        title.textColor = Theme.foreground
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = Theme.sans(13)
        subtitle.textColor = Theme.mutedForeground
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        accessory.font = Theme.meta
        accessory.textColor = Theme.mutedForeground.withAlphaComponent(0.8)
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)

        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chipLabel.font = Theme.label
        chipLabel.alignment = .center
        chipLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chipLabel.setContentHuggingPriority(.required, for: .horizontal)
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)

        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 2
        runningDot.layer?.backgroundColor = Theme.foreground.withAlphaComponent(0.85).cgColor
        runningDot.isHidden = true

        for v in [icon, title, subtitle, accessory, chip, runningDot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            runningDot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            runningDot.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            runningDot.widthAnchor.constraint(equalToConstant: 4),
            runningDot.heightAnchor.constraint(equalToConstant: 4),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor, constant: 12),
            chip.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 18),
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            chipLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor, constant: 12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            accessory.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Cells are reconfigured in place on every keystroke; only touch what changed,
    /// since each text change invalidates layout.
    func configure(_ item: Item) {
        let image = IconCache.shared.image(for: item.icon)
        if icon.image !== image { icon.image = image }
        let tint: NSColor? = if case .symbol(_, let tint) = item.icon { tint ?? .secondaryLabelColor } else { nil }
        if icon.contentTintColor != tint { icon.contentTintColor = tint }
        if runningDot.isHidden == item.isRunning { runningDot.isHidden = !item.isRunning }
        Self.set(title, item.title)
        let font = item.monoTitle ? Theme.mono(15, 500) : Theme.body
        if title.font != font { title.font = font }
        Self.set(subtitle, item.subtitle ?? "")
        Self.set(accessory, item.accessory ?? "")
        if let c = item.chip {
            if chip.isHidden { chip.isHidden = false }
            Self.set(chipLabel, c.text)
            if chipLabel.textColor != c.color {
                chipLabel.textColor = c.color
                chip.layer?.backgroundColor = c.color.withAlphaComponent(0.15).cgColor
            }
        } else if !chip.isHidden {
            chip.isHidden = true
        }
    }

    private static func set(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }
}

final class SectionHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    private let label = NSTextField(labelWithString: "")
    private let rule = NSView()

    /// DS SectionHeading: a micro-label followed by a hairline rule.
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.border.cgColor
        for v in [label, rule] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var title: String?

    func configure(_ title: String) {
        guard title != self.title else { return }
        self.title = title
        label.attributedStringValue = Theme.labelString(title)
    }
}

/// Calculator card: the parsed expression on the left, the result on the right.
final class CalculationCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CalculationCell")

    private let expression = NSTextField(labelWithString: "")
    private let result = NSTextField(labelWithString: "")
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let arrow = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        for f in [expression, result] {
            f.alignment = .center
            f.lineBreakMode = .byTruncatingMiddle
            f.textColor = Theme.foreground
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        expression.font = Theme.mono(22)
        expression.textColor = Theme.foreground.withAlphaComponent(0.85)
        result.font = Theme.mono(28, 500)
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        arrow.contentTintColor = Theme.mutedForeground

        let left = Self.column(expression, label: leftLabel)
        let right = Self.column(result, label: rightLabel)
        for v in [left, arrow, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            left.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -16),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func column(_ value: NSTextField, label: NSTextField) -> NSStackView {
        label.alignment = .center
        let stack = NSStackView(views: [value, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        return stack
    }

    func configure(_ expression: String, _ result: String, left: String, right: String) {
        self.expression.stringValue = expression
        self.result.stringValue = result
        leftLabel.attributedStringValue = Theme.labelString(left)
        rightLabel.attributedStringValue = Theme.labelString(right)
    }
}
