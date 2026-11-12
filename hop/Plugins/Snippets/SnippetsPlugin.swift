import AppKit
import os

/// Snippets: insert by name from the launcher, or expand a typed keyword anywhere.
final class SnippetsPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "snippets", name: "Snippets", summary: "Text you insert by name or by typing a keyword.",
                   symbol: "text.badge.plus", color: Palette.snippets, category: .keyboard, enabledPath: ["snippets", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("snippets.enabled", "Snippets", .toggle),
                .setting("snippets.expand", "Expand keywords", .toggle, "Type a snippet's keyword anywhere and it becomes the snippet (needs Accessibility)."),
                .setting("snippets.expandWithinWords", "Expand within words", .toggle, "Also expand keywords typed in the middle of a word."),
                .setting("snippets.disabledApps", "Never expand in", .list(placeholder: "com.apple.Terminal"), "Bundle identifiers, comma-separated.", check: SettingsChecks.bundleIDs),
                .setting("snippets.file", "Snippets file", .text(placeholder: "~/.config/hop/snippets.json5"), "\"Edit Snippets\" in hop opens it.", check: SettingsChecks.file),
            ]),
        ]
    }

    init() {}

    private(set) var service: SnippetService!
    private let expander = SnippetExpander()
    private var expanderRetry: Timer?
    private weak var host: PluginHost?

    /// Needs the clipboard plugin's store: start it after `ClipboardPlugin`.
    func start(_ host: PluginHost) {
        self.host = host
        let file = SnippetsFile(url: URL(fileURLWithPath: host.settings.data.snippets.file.expandingTilde))
        service = SnippetService(file: file, clipboard: host.plugin(ClipboardPlugin.self)?.store)
        service.presentArguments = { [weak host] mode in host?.present(mode) }
        file.onChange = { [weak self] in
            self?.updateExpanderKeywords()
            self?.host?.rebuildRoot()
        }
        expander.onMatch = { [weak self] index, keyword in
            guard let self, index < service.snippets.count else { return }
            service.insert(service.snippets[index], keyword: keyword)
        }
        file.start()
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        guard previous?.snippets != config.snippets else { return }
        let url = URL(fileURLWithPath: config.snippets.file.expandingTilde)
        if previous != nil && service.file.url != url {
            service.file.url = url
            service.file.start()
        }
        expander.withinWords = config.snippets.expandWithinWords
        expander.disabledApps = Set(config.snippets.disabledApps)
        updateExpander(config.snippets)
    }

    func commands() -> [Item] { SnippetCommands.items(host!.services) }

    func setAway(_ away: Bool) {
        if away {
            expanderRetry?.invalidate()
            expanderRetry = nil
        } else if !expander.isRunning, let host {
            // Starts it now if Accessibility was granted meanwhile, otherwise retries again.
            updateExpander(host.settings.data.snippets)
        }
    }

    func stop() { expander.stop() }

    private func updateExpanderKeywords() {
        expander.keywords = service.snippets.enumerated().compactMap { i, s in s.keyword.map { ($0, i) } }
    }

    /// Starts the expander when wanted; without Accessibility it retries until granted.
    private func updateExpander(_ config: HopConfig.Snippets) {
        expanderRetry?.invalidate()
        expanderRetry = nil
        guard config.enabled && config.expand else {
            expander.stop()
            return
        }
        updateExpanderKeywords()
        if expander.start() { return }
        Log.app.notice("snippets: expansion waits for Accessibility")
        guard host?.isAway != true else { return }
        let retry = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.expander.start() else { return }
                self.expanderRetry?.invalidate()
                self.expanderRetry = nil
            }
        }
        retry.tolerance = 2
        RunLoop.main.add(retry, forMode: .common)
        expanderRetry = retry
    }
}

extension Services {
    var snippets: SnippetService? { plugin(SnippetsPlugin.self)?.service }
}
