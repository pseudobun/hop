import AppKit

/// What Show Changes (⌘D) found in a session's folder: `AgentCommands.diffScript` output.
nonisolated struct GitChanges: Equatable, Sendable {
    /// Checked-out branch, or "detached".
    var branch = ""
    /// The branch a hop worktree forked from (the diff is against their merge base); nil otherwise.
    var base: String?
    /// `git status --short` lines.
    var status: [String] = []
    var diff = ""

    var isClean: Bool { status.isEmpty && diff.isEmpty }

    static func parse(_ text: String) -> GitChanges {
        var out = GitChanges()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let split = lines.firstIndex(of: "D|") ?? lines.endIndex
        if split < lines.endIndex { out.diff = lines[(split + 1)...].joined(separator: "\n") }
        for line in lines[..<split] {
            if line.hasPrefix("B|") {
                let parts = line.dropFirst(2).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                out.branch = parts.first ?? ""
                out.base = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            } else if line.hasPrefix("S|") {
                out.status.append(String(line.dropFirst(2)))
            }
        }
        if out.diff.hasSuffix("\n") { out.diff.removeLast() }
        return out
    }

    /// How a diff line is drawn.
    enum Style: Equatable { case added, removed, hunk, file, context }

    static func style(_ line: Substring) -> Style {
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("rename ") || line.hasPrefix("similarity ") { return .file }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}

extension GitChanges {
    /// Status, then the diff coloured: additions good, removals destructive, hunk headers muted.
    func rendered(cwd: String, maxLines: Int = 6000) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let tight = NSMutableParagraphStyle()
        tight.paragraphSpacing = 0
        let gap = NSMutableParagraphStyle()
        gap.paragraphSpacing = 10
        var head = "\(branch) · \(cwd)"
        if let base { head += " · since it forked from \(base)" }
        out.append(Theme.labelString(head))
        out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono(12), .paragraphStyle: gap]))
        if isClean {
            out.append(NSAttributedString(string: "No changes\n", attributes: [.font: Theme.meta, .foregroundColor: Theme.mutedForeground]))
            return out
        }
        for line in status {
            let code = String(line.prefix(2))
            let color: NSColor = code.contains("?") ? Theme.mutedForeground
                : code.contains("D") ? Theme.destructive : code.contains("A") ? Theme.good : Theme.warn
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: Theme.mono(12), .foregroundColor: color, .paragraphStyle: tight,
            ]))
        }
        if !status.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono(8)])) }
        var count = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            count += 1
            if count > maxLines {
                out.append(NSAttributedString(string: "… \(diff.split(separator: "\n").count - maxLines) more lines\n", attributes: [
                    .font: Theme.meta, .foregroundColor: Theme.mutedForeground,
                ]))
                break
            }
            let (font, color): (NSFont, NSColor) = switch Self.style(line) {
            case .added: (Theme.mono(12), Theme.good)
            case .removed: (Theme.mono(12), Theme.destructive)
            case .hunk: (Theme.mono(12), Theme.mutedForeground)
            case .file: (Theme.mono(12, 600), Theme.info)
            case .context: (Theme.mono(12), Theme.foreground.withAlphaComponent(0.85))
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: tight]))
        }
        return out
    }
}
