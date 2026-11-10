import Foundation
import os

nonisolated enum AppPaths {
    /// hop.app's bundle identifier (`HOP_BUNDLE_ID` in Local.xcconfig). It names the
    /// support and cache folders, the log subsystem, Keychain items and notifications,
    /// so each build identity keeps its own data.
    static let bundleID: String = appBundle.bundleIdentifier ?? "dev.hop.app"

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: bundleID, directoryHint: .isDirectory)
    }()

    static func file(_ name: String) -> URL { supportDir.appending(path: name) }

    /// hop.app, also when the CLI runs through a symlink (/opt/homebrew/bin/hop), where
    /// `Bundle.main` is the symlink's folder and has no resources.
    static let appBundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        // argv[0] is just "hop" when run from PATH; the kernel knows the real file.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)))
        guard length > 0 else { return .main }
        let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app) ?? .main
    }()

    /// CFBundleShortVersionString, e.g. "0.1.0-beta.1" (VERSION; local builds stamp it too).
    static var version: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    /// CFBundleVersion, which Sparkle compares: the commit count of the release.
    static var build: String { appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Bundle ids hop used before com.pseudobun.hop (the default of builds from source).
    static let legacyBundleIDs = ["dev.hop.app"]

    /// The first launch under a new bundle id copies the support folder and preferences of
    /// the most recently used earlier id, so clipboard history, frecency and shelves carry
    /// over. Copied, not moved: a build that still uses the old id keeps working.
    /// Keychain items (KeePassXC, OpenAI) and macOS permissions don't carry over.
    static func migrateLegacyData(fileManager fm: FileManager = .default) {
        guard !isRunningTests, !legacyBundleIDs.contains(bundleID) else { return }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard !fm.fileExists(atPath: supportDir.path) else { return }
        let candidates = legacyBundleIDs.compactMap { id -> (String, URL, Date)? in
            let dir = base.appending(path: id, directoryHint: .isDirectory)
            guard let date = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (id, dir, date)
        }
        guard let (id, dir, _) = candidates.max(by: { $0.2 < $1.2 }) else { return }
        do {
            try fm.copyItem(at: dir, to: supportDir)
            if let prefs = UserDefaults.standard.persistentDomain(forName: id), !prefs.isEmpty {
                UserDefaults.standard.setPersistentDomain(prefs, forName: bundleID)
            }
            Log.app.info("migrated data from \(id, privacy: .public)")
        } catch {
            Log.app.error("migrate \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
