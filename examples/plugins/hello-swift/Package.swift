// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelloSwift",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../../sdk/swift")],
    targets: [
        .executableTarget(name: "HelloSwift", dependencies: [.product(name: "HopPluginKit", package: "swift")]),
    ]
)
