import AppKit
import os

/// New hop versions from the GitHub releases of `HopUpdateRepository` (Info.plist). Release
/// builds set it; builds from source leave it empty and never check. hop doesn't replace
/// itself (an updater framework would bring WebKit along): it says that a version is out and
/// how to get it, `brew upgrade --cask pseudobun/tap/hop` or the release page.
@MainActor
final class Updater {
    static let shared = Updater()
    static let brewCommand = "brew upgrade --cask pseudobun/tap/hop"

    enum State: Equatable {
        case idle, checking
        case available(ReleaseInfo)
        case upToDate
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Not checked yet"
            case .checking: return "Checking…"
            case .available(let r): return "hop \(r.version) is available"
            case .upToDate: return "hop \(AppPaths.version) is the newest version"
            case .failed(let e): return "Update check failed: \(e)"
            }
        }
    }

    private(set) var state = State.idle
    private var timer: Timer?
    private var task: Task<Void, Never>?

    /// "owner/name" from Info.plist, nil for builds from source.
    nonisolated static var repository: String? {
        let repo = AppPaths.appBundle.object(forInfoDictionaryKey: "HopUpdateRepository") as? String ?? ""
        return repo.isEmpty || repo.hasPrefix("$(") ? nil : repo
    }

    var isAvailable: Bool { Self.repository != nil }

    func start(_ config: HopConfig.Updates) { apply(config) }

    /// Once a day while `updates.check` is on, the first time shortly after launch.
    func apply(_ config: HopConfig.Updates) {
        timer?.invalidate()
        timer = nil
        guard isAvailable, config.check else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(manual: false) }
        }
        if state == .idle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.state == .idle { self?.check(manual: false) }
            }
        }
    }

    /// Menu bar bunny and Settings: check now and say what came out.
    func checkNow() { check(manual: true) }

    /// What a menu item offers right now.
    var menuTitle: String {
        if case .available(let r) = state { return "Update to hop \(r.version)…" }
        return "Check for Updates…"
    }

    private func check(manual: Bool) {
        guard let repo = Self.repository else {
            if manual { present(.failed("this hop was built from source; update it with git pull and just install")) }
            return
        }
        guard task == nil else { return }
        if manual, case .available = state { present(state); return }
        state = .checking
        task = Task {
            let result: State
            do {
                let current = AppPaths.version
                if let r = try await ReleaseFeed.latest(repository: repo, includePrereleases: ReleaseVersion.isPrerelease(current)),
                   ReleaseVersion.isNewer(r.version, than: current) {
                    result = .available(r)
                } else {
                    result = .upToDate
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            state = result
            task = nil
            Log.app.info("updates: \(result.text, privacy: .public)")
            if manual { present(result) }
        }
    }

    private func present(_ s: State) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        switch s {
        case .available(let r):
            alert.messageText = "hop \(r.version) is available"
            alert.informativeText = "You have \(AppPaths.version). Installed with Homebrew? Update with:\n\n\(Self.brewCommand)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
        case .failed(let e):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = e
        default:
            alert.messageText = "You're up to date"
            alert.informativeText = "hop \(AppPaths.version) is the newest version."
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard case .available(let r) = s else { return }
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.brewCommand, forType: .string)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(r.url)
        default: break
        }
    }
}

nonisolated struct ReleaseInfo: Equatable, Sendable {
    let version: String
    let url: URL
}

/// The releases list of a GitHub repository.
nonisolated enum ReleaseFeed {
    struct Release: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }

    static func latest(repository: String, includePrereleases: Bool) async throws -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("hop/\(AppPaths.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode)"])
        }
        return pick(try JSONDecoder().decode([Release].self, from: data), includePrereleases: includePrereleases)
    }

    /// The highest version among published releases; betas only when asked.
    static func pick(_ releases: [Release], includePrereleases: Bool) -> ReleaseInfo? {
        releases
            .filter { !$0.draft && (includePrereleases || !$0.prerelease) }
            .compactMap { r in URL(string: r.html_url).map { ReleaseInfo(version: ReleaseVersion.clean(r.tag_name), url: $0) } }
            .max { ReleaseVersion.isNewer($1.version, than: $0.version) }
    }
}

/// Semantic versions as release-please writes them: "0.1.0", "0.2.0-beta.3", tags with a "v".
nonisolated enum ReleaseVersion {
    static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("v") ? String(t.dropFirst()) : t
    }

    static func isPrerelease(_ s: String) -> Bool { clean(s).contains("-") }

    static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) == .orderedDescending }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (coreA, preA) = split(clean(a)), (coreB, preB) = split(clean(b))
        for i in 0..<max(coreA.count, coreB.count) {
            let x = i < coreA.count ? coreA[i] : 0, y = i < coreB.count ? coreB[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        // A release ranks above its prereleases.
        switch (preA.isEmpty, preB.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for i in 0..<max(preA.count, preB.count) {
            guard i < preA.count else { return .orderedAscending }
            guard i < preB.count else { return .orderedDescending }
            let x = preA[i], y = preB[i]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func split(_ v: String) -> ([Int], [String]) {
        let noBuild = v.split(separator: "+", maxSplits: 1).first.map(String.init) ?? v
        let parts = noBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return (core, pre)
    }
}
