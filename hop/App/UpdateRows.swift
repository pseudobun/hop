import AppKit

/// "Update hop" and "Update paw" at the top of the empty launcher once a version is downloaded
/// (each app's `update.json`); ↵ installs it and restarts that app.
enum UpdateRows {
    static let pawBundleID = "com.pseudobun.paw"

    static func items() -> [Item] {
        var items: [Item] = []
        if Updater.shared.isAvailable, let v = Updater.shared.pending {
            items.append(Item(id: "update.hop", title: "Update hop to \(v)", subtitle: "Downloaded · ↵ installs it and restarts hop",
                              icon: .tile("arrow.down.circle.fill", Theme.info), accessory: "Update",
                              actions: [Action(title: "Install and Restart", symbol: "arrow.down.circle") {
                                  Updater.shared.installNow()
                                  return .dismiss
                              }], tracksFrecency: false))
        }
        if let p = PendingUpdate.read(at: PendingUpdate.url(bundleID: pawBundleID)), Paw.executable != nil, isNewerPaw(p) {
            items.append(Item(id: "update.paw", title: "Update paw to \(p.version)", subtitle: "Downloaded · ↵ installs it and restarts paw",
                              icon: .tile("arrow.down.circle.fill", Theme.info), accessory: "Update",
                              actions: [Action(title: "Install and Restart paw", symbol: "arrow.down.circle") {
                                  Task { await Paw.update() }
                                  return .dismissWithHUD("Updating paw to \(p.version)…")
                              }], tracksFrecency: false))
        }
        return items
    }

    /// paw clears its file once the version runs; this covers a paw that hasn't started since.
    private static func isNewerPaw(_ p: PendingUpdate.Info) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pawBundleID),
              let build = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return true }
        return (Int(p.build) ?? 0) > (Int(build) ?? 0)
    }
}
