import os

nonisolated enum Log {
    static let app = Logger(subsystem: "dev.hop.app", category: "app")
    static let search = Logger(subsystem: "dev.hop.app", category: "search")
    static let hyper = Logger(subsystem: "dev.hop.app", category: "hyper")
    static let keepass = Logger(subsystem: "dev.hop.app", category: "keepass")
    static let wireguard = Logger(subsystem: "dev.hop.app", category: "wireguard")
}
