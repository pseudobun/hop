import Foundation

/// Claude Code's folder trust. A session started in a folder nobody trusted yet stops at
/// "Quick safety check: Is this a project you created or one you trust?" and does nothing
/// else (Remote Control included) until someone answers it. hop reads the answer Claude
/// recorded and spots the dialog on screen; it never answers it on its own.
nonisolated enum ClaudeTrust {
    // MARK: - Recorded trust (~/.claude.json, read only)

    /// Folders with `projects[<abs path>].hasTrustDialogAccepted: true` in `~/.claude.json`.
    static func trustedFolders(claudeJSON data: Data) -> Set<String> {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = o["projects"] as? [String: Any] else { return [] }
        return Set(projects.compactMap { path, value in
            ((value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool) == true ? path : nil
        })
    }

    /// Whether Claude Code would start in `cwd` without asking. Like Claude Code 2.1: the
    /// record of the git root (or of the folder itself outside git) counts, and so does one
    /// of a folder above, but inside a git repository only up to its root: a trusted
    /// `~/repos` does not cover the repository `~/repos/app`.
    /// `cwd` and `gitRoot` are absolute paths with symlinks resolved.
    static func isTrusted(cwd: String, gitRoot: String?, trusted: Set<String>) -> Bool {
        if trusted.contains(gitRoot ?? cwd) { return true }
        var dir = normalized(cwd)
        let stop = gitRoot.map(normalized)
        while true {
            if let stop, dir != stop && !dir.hasPrefix(stop == "/" ? "/" : stop + "/") { return false }
            if trusted.contains(dir) { return true }
            if dir == stop || dir == "/" { return false }
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty { dir = "/" }
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The closest folder at or above `path` that holds `.git` (a folder, or a file in a worktree).
    static func gitRoot(of path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var dir = normalized(path)
        while true {
            if exists((dir as NSString).appendingPathComponent(".git")) { return dir }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty { return nil }
        }
    }

    nonisolated(unsafe) private static var cache: (stamp: AgentStore.FileStamp, trusted: Set<String>)?
    private static let lock = NSLock()

    static var configFile: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json") }

    /// Trust of a folder on this Mac: true, false, or nil when it is not a folder or
    /// `~/.claude.json` cannot be read. The file is parsed again only when it changed.
    static func isTrusted(localFolder: String) -> Bool? {
        let path = localFolder.expandingTilde
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let file = configFile.path
        guard let stamp = AgentStore.FileStamp.of(file) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if cache?.stamp != stamp {
            guard let data = FileManager.default.contents(atPath: file) else { return nil }
            cache = (stamp, trustedFolders(claudeJSON: data))
        }
        guard let trusted = cache?.trusted else { return nil }
        // Claude Code canonicalizes /tmp to /private/tmp; either spelling may be on record.
        return isTrusted(cwd: real, gitRoot: gitRoot(of: real), trusted: trusted)
            || (real != path && isTrusted(cwd: path, gitRoot: gitRoot(of: path), trusted: trusted))
    }

    // MARK: - The dialog on screen (tmux capture-pane)

    static let yesOption = "Yes, I trust this folder"

    /// The screen shows Claude Code's trust dialog.
    static func isPrompt(_ screen: String) -> Bool {
        screen.contains(yesOption) && (screen.contains("Quick safety check") || screen.contains("Accessing workspace")
            || screen.contains("Do you trust the files in this folder"))
    }

    /// The highlighted choice ("❯ …") is the Yes option.
    static func isYesSelected(_ screen: String) -> Bool {
        screen.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("❯") && t.contains(yesOption)
        }
    }

    /// Bash that answers the dialog in a hop tmux session: only while it is on screen, it moves
    /// to "Yes, I trust this folder", checks that is what is highlighted, and confirms.
    /// Exit 6: no dialog; 7: Yes could not be selected (nothing confirmed).
    static func confirmScript(tmux: String, session: String) -> String {
        let t = AgentCommands.quote(tmux)
        let target = AgentCommands.quote("=\(session):")
        return confirmScript(capture: "\(t) capture-pane -p -t \(target)", down: "\(t) send-keys -t \(target) Down",
                             enter: "\(t) send-keys -t \(target) Enter", what: "tmux session \(session)")
    }

    /// The same for an agent in herdr (`agent read`, `agent send-keys`).
    static func confirmScript(herdr: String, agent: String) -> String {
        let h = AgentCommands.quote(herdr)
        let a = AgentCommands.quote(agent)
        return confirmScript(capture: "\(h) agent read \(a) --source visible", down: "\(h) agent send-keys \(a) down",
                             enter: "\(h) agent send-keys \(a) enter", what: "herdr agent \(agent)")
    }

    private static func confirmScript(capture: String, down: String, enter: String, what: String) -> String {
        """
        s=$(\(capture) 2>/dev/null) || { echo "no \(what)" >&2; exit 5; }
        case "$s" in *\(quoteForCase(yesOption))*) ;; *) echo "no trust question on screen" >&2; exit 6 ;; esac
        i=0
        while [ $i -lt 3 ]; do
          printf '%s\\n' "$s" | grep -q '❯ *\(yesOption)' && break
          \(down) >/dev/null
          sleep 0.3
          s=$(\(capture) 2>/dev/null)
          i=$((i+1))
        done
        printf '%s\\n' "$s" | grep -q '❯ *\(yesOption)' || { echo "could not select “\(yesOption)”" >&2; exit 7; }
        \(enter) >/dev/null
        """
    }

    private static func quoteForCase(_ s: String) -> String {
        s.map { $0 == " " || $0 == "," ? "\\\($0)" : String($0) }.joined()
    }
}
