// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HopPluginKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HopPluginKit", targets: ["HopPluginKit"])],
    targets: [
        .target(name: "HopPluginKit"),
        .testTarget(name: "HopPluginKitTests", dependencies: ["HopPluginKit"]),
    ]
)
