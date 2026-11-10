import AppKit
import os
import Sparkle

/// Sparkle updates from the appcast on GitHub (SUFeedURL, SUPublicEDKey in Info.plist). Release
/// builds set both; builds from source leave them empty and never check.
///
/// Checks you start (menu bar bunny, Settings, `hop update`) first probe the feed without UI:
/// Sparkle's own "up to date" and error alerts are modal and would stall the main queue, and with
/// it hop's hotkeys, until dismissed. Only a found update opens Sparkle's (non-modal) window;
/// the rest goes to the HUD.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    /// `hop update` posts this; the running hop checks.
    static let checkNotification = Notification.Name(AppPaths.bundleID + ".update.check")

    enum State: Equatable {
        case idle, checking
        case available(String)
        case upToDate
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Not checked yet"
            case .checking: return "Checking…"
            case .available(let v): return "hop \(v) is available"
            case .upToDate: return "hop \(AppPaths.version) is the newest version"
            case .failed(let e): return "Update check failed: \(e)"
            }
        }
    }

    private(set) var state = State.idle
    private var controller: SPUStandardUpdaterController?
    private var cliObserver: NSObjectProtocol?
    /// The version the probe found; shown once its cycle has ended (Sparkle ignores a check
    /// started while another runs).
    private var found: String?

    /// Release builds carry a feed and a public key; builds from source don't.
    nonisolated static var isConfigured: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            let v = AppPaths.appBundle.object(forInfoDictionaryKey: key) as? String ?? ""
            return !v.isEmpty && !v.hasPrefix("$(")
        }
    }

    var isAvailable: Bool { controller != nil }

    func start(_ config: HopConfig.Updates) {
        guard controller == nil, Self.isConfigured else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        apply(config)
        do { try c.updater.start() } catch {
            Log.app.error("updater: \(error.localizedDescription, privacy: .public)")
            controller = nil
            return
        }
        cliObserver = DistributedNotificationCenter.default().addObserver(forName: Self.checkNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.checkNow() }
        }
    }

    func apply(_ config: HopConfig.Updates) {
        guard let u = controller?.updater else { return }
        u.automaticallyChecksForUpdates = config.check
        u.automaticallyDownloadsUpdates = config.check && config.automatic
        u.updateCheckInterval = 24 * 60 * 60
    }

    /// Menu bar bunny, Settings and `hop update`: probe, then show Sparkle's window only for a new version.
    func checkNow() {
        guard let u = controller?.updater else {
            HUD.shared.fail("This hop was built from source; update it with git pull and just install")
            return
        }
        guard state != .checking else { return }
        guard u.canCheckForUpdates else {
            // A check (or an update) is already under way; bring its window forward.
            NSApp.activate(ignoringOtherApps: true)
            controller?.checkForUpdates(nil)
            return
        }
        state = .checking
        found = nil
        u.checkForUpdateInformation()
    }

    private func finish(_ s: State) {
        guard state == .checking else { return }
        state = s
        Log.app.info("updates: \(s.text, privacy: .public)")
        switch s {
        case .available: showWindow(tries: 30)
        case .failed(let e): HUD.shared.fail("Update check failed: \(e)")
        default: HUD.shared.show(s.text)
        }
    }

    /// Sparkle's window for the found update, once the probe's session has let go (a check
    /// started before that is ignored).
    private func showWindow(tries: Int) {
        guard let controller else { return }
        guard controller.updater.canCheckForUpdates else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.showWindow(tries: tries - 1) }
            } else {
                Log.app.error("updates: Sparkle stayed busy; no window")
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func found(_ v: String) {
        guard state == .checking else { return }
        found = v
    }

    private func cycleEnded(_ error: String?) {
        guard state == .checking else { return }
        if let v = found { finish(.available(v)) } else { finish(.failed(error ?? "no answer")) }
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        Task { @MainActor in self.found(v) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor in self.finish(.upToDate) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let message = error.map { ($0 as NSError).localizedDescription }
        Task { @MainActor in self.cycleEnded(message) }
    }
}
