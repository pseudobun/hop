import Foundation

nonisolated enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "dev.hop.app", directoryHint: .isDirectory)
    }()

    static func file(_ name: String) -> URL { supportDir.appending(path: name) }

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
