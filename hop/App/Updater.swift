import AppKit
import os
import Sparkle

/// Sparkle updates without Sparkle's windows: once a day hop looks at the appcast (SUFeedURL),
/// downloads a new version in the background and installs it when hop quits, or right away with
/// the launcher's "Update hop" row, the menu bar bunny, `hop update`, or `updates.automatic`.
/// Only release builds carry a feed and key; builds from source never check.
///
/// A version waiting to install is written to `update.json` in hop's Application Support folder;
/// paw writes the same file in its own, which is how the launcher offers paw's updates too.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    /// `hop update` posts these; the running hop answers.
    static let installNotification = Notification.Name(AppPaths.bundleID + ".update.install")
    static let checkNotification = Notification.Name(AppPaths.bundleID + ".update.check")

    enum State: Equatable {
        case idle, checking
        case installing(String)
        case available(String)
        case upToDate
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Not checked yet"
            case .checking: return "Checking…"
            case .installing(let v): return "Installing hop \(v); hop restarts"
            case .available(let v): return "hop \(v) is available"
            case .upToDate: return "hop \(AppPaths.version) is the newest version"
            case .failed(let e): return "Update check failed: \(e)"
            }
        }
    }

    private(set) var state = State.idle
    /// A version found or downloaded that hasn't been installed yet.
    private(set) var pending: String?
    /// Runs when a check you started has an answer.
    var onResult: ((State) -> Void)?

    private var updater: SPUUpdater?
    private let driver = SilentUserDriver()
    private var config = HopConfig.Updates()
    /// Sparkle's "install the downloaded update now and relaunch".
    private var installNowHandler: (() -> Void)?
    /// `checkOnly` runs: look, don't install.
    private var probing = false
    private var found: String?

    private var observers: [NSObjectProtocol] = []

    var isAvailable: Bool { updater != nil }

    /// The menu bar bunny's item.
    var menuTitle: String { pending.map { "Update to hop \($0)…" } ?? "Check for Updates…" }

    /// Release builds carry a feed and a public key; builds from source don't.
    nonisolated static var isConfigured: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            let v = AppPaths.appBundle.object(forInfoDictionaryKey: key) as? String ?? ""
            return !v.isEmpty && !v.hasPrefix("$(")
        }
    }

    func start(_ config: HopConfig.Updates) {
        guard updater == nil, Self.isConfigured else { return }
        PendingUpdate.clearIfInstalled()
        pending = PendingUpdate.read()?.version
        driver.owner = self
        let u = SPUUpdater(hostBundle: AppPaths.appBundle, applicationBundle: AppPaths.appBundle, userDriver: driver, delegate: self)
        updater = u
        apply(config)
        do { try u.start() } catch {
            Log.app.error("updater: \(error.localizedDescription, privacy: .public)")
            updater = nil
            return
        }
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: Self.installNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.installNow() }
            },
            center.addObserver(forName: Self.checkNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.checkOnly() }
            },
        ]
    }

    func apply(_ config: HopConfig.Updates) {
        self.config = config
        guard let u = updater else { return }
        u.automaticallyChecksForUpdates = config.check
        // Always in the background; `automatic` decides whether it also installs right away.
        u.automaticallyDownloadsUpdates = config.check
        u.updateCheckInterval = 24 * 60 * 60
        if config.automatic, let installNowHandler { install(pending ?? "", installNowHandler) }
    }

    /// Launcher row, menu bar bunny, `hop update`: install the newest version now, downloading it first if needed.
    func installNow() {
        guard let u = updater, state != .checking else { return }
        if case .installing = state { return }
        if let installNowHandler { install(pending ?? "", installNowHandler); return }
        guard u.canCheckForUpdates else { return }
        state = .checking
        u.checkForUpdates()
    }

    /// `hop update --check`: look without installing.
    func checkOnly() {
        guard let u = updater, state != .checking else { return }
        guard u.canCheckForUpdates else {
            // A downloaded update holds the cycle; it is the answer.
            if let pending { finish(.available(pending)) }
            return
        }
        state = .checking
        probing = true
        found = nil
        u.checkForUpdateInformation()
    }

    private func install(_ version: String, _ handler: () -> Void) {
        state = .installing(version)
        Log.app.info("updates: \(self.state.text, privacy: .public)")
        report(state)
        handler()
    }

    private func finish(_ s: State) {
        state = s
        probing = false
        Log.app.info("updates: \(s.text, privacy: .public)")
        report(s)
    }

    /// The HUD, unless `onResult` takes it.
    private func report(_ s: State) {
        if let onResult { onResult(s); return }
        switch s {
        case .failed(let e): HUD.shared.fail("Update check failed: \(e)")
        case .idle, .checking: break
        default: HUD.shared.show(s.text)
        }
    }

    private func markPending(_ version: String, build: String) {
        pending = version
        PendingUpdate.write(.init(version: version, build: build))
    }

    // MARK: - From the user driver (main thread)

    func updateFound(_ item: SUAppcastItem, userInitiated: Bool) -> SPUUserUpdateChoice {
        if userInitiated || config.automatic {
            state = .installing(item.displayVersionString)
            report(state)
            return .install
        }
        // A scheduled check that didn't download (Sparkle won't for some updates): offer it.
        markPending(item.displayVersionString, build: item.versionString)
        return .dismiss
    }

    func noUpdate() { if state == .checking { finish(.upToDate) } }

    func failed(_ error: Error) {
        if state == .checking || isInstalling { finish(.failed((error as NSError).localizedDescription)) }
    }

    private var isInstalling: Bool { if case .installing = state { return true } else { return false } }
}

// Sparkle calls its delegate and user driver on the main thread.
extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if probing { found = item.displayVersionString }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if probing { finish(.upToDate) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard probing else { return }
        if let found { finish(.available(found)) } else { finish(.failed(error.map { ($0 as NSError).localizedDescription } ?? "no answer")) }
    }

    /// Downloaded in the background: hold it until hop quits or someone asks for it.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        installNowHandler = immediateInstallHandler
        markPending(v, build: item.versionString)
        Log.app.info("updates: hop \(v, privacy: .public) downloaded")
        if config.automatic { install(v, immediateInstallHandler) }
        return true
    }
}

/// Sparkle's user interface, without any: every answer comes from `Updater`.
@MainActor
final class SilentUserDriver: NSObject {
    weak var owner: Updater?
}

extension SilentUserDriver: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Config decides; SUEnableAutomaticChecks keeps Sparkle from asking anyway.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(owner?.updateFound(appcastItem, userInitiated: state.userInitiated) ?? .dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.noUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Only reached after an update was accepted (`updateFound` said install).
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}

/// `update.json` in the app's Application Support folder: the version waiting to install.
/// paw writes the same file in its own folder; `PendingUpdate.read(at:)` reads either.
nonisolated enum PendingUpdate {
    struct Info: Codable, Equatable, Sendable {
        let version: String
        let build: String
    }

    static var url: URL { AppPaths.file("update.json") }

    /// Another app's, by bundle id: paw's is `com.pseudobun.paw`.
    static func url(bundleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: bundleID, directoryHint: .isDirectory).appending(path: "update.json")
    }

    static func read(at url: URL = url) -> Info? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    static func write(_ info: Info) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: url, options: .atomic) }
    }

    /// Gone once this build (or a newer one) runs.
    static func clearIfInstalled() {
        guard let info = read() else { return }
        let current = Int(AppPaths.appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        if (Int(info.build) ?? 0) <= current { try? FileManager.default.removeItem(at: url) }
    }
}
