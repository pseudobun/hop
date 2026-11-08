import os

nonisolated enum Log {
    static let app = Logger(subsystem: AppPaths.bundleID, category: "app")
    static let search = Logger(subsystem: AppPaths.bundleID, category: "search")
    static let hyper = Logger(subsystem: AppPaths.bundleID, category: "hyper")
    static let keepass = Logger(subsystem: AppPaths.bundleID, category: "keepass")
    static let wireguard = Logger(subsystem: AppPaths.bundleID, category: "wireguard")
}
