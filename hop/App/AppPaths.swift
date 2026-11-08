import Foundation

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

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
