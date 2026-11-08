import AppKit

/// Root commands for the Agents panel.
enum AgentsCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.agents
        guard config.enabled, let agents = services.agents else { return [] }
        let hotkey = HotkeySpec.parse(config.hotkey).map { _ in NotesCommands.display(config.hotkey) }
        return [
            Item(id: "agents.open", title: "Agents", subtitle: "Claude Code and OpenCode sessions: status, transcript, attach",
                 aliases: ["claude sessions", "opencode", "coding agents"],
                 icon: .tile("sparkles", Palette.agents), accessory: hotkey ?? "Command",
                 actions: [Action(title: "Open Agents", symbol: "sparkles") {
                     agents.show()
                     return .dismiss
                 }]),
            Item(id: "agents.new", title: "New Agent Session", subtitle: "Start Claude Code or OpenCode in tmux, here or over ssh",
                 icon: .tile("plus", Palette.agents), accessory: "Command",
                 actions: [Action(title: "New Agent Session", symbol: "plus") {
                     agents.show(newSession: true)
                     return .dismiss
                 }]),
        ]
    }
}
