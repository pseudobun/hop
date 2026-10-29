import Foundation

nonisolated enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "dev.hop.app", directoryHint: .isDirectory)
    }()

    static func file(_ name: String) -> URL { supportDir.appending(path: name) }

    /// hop.app, also when the CLI runs through a symlink (/opt/homebrew/bin/hop), where
    /// `Bundle.main` is the symlink's folder and has no resources.
    static let appBundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        // argv[0] is just "hop" when run from PATH; the kernel knows the real file.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return .main }
        let exe = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app) ?? .main
    }()

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
