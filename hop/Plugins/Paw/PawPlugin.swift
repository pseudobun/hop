import AppKit

/// paw: setups and updates for the paw window manager.
final class PawPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "paw", name: "paw", summary: "Setups for the paw window manager.", symbol: "rectangle.3.group.fill",
                   color: Theme.chart4, category: .integrations)
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { PawCommands.items(host!.services) }
}
