import AppKit
import UniformTypeIdentifiers

/// "Theme": pick one of hop's themes or your own. The selected row previews it live; ↵ writes
/// it to `general.theme`, where the config watcher applies it everywhere. Your themes are
/// .json5 files in `~/.config/hop/themes/` (CustomThemes); the picker can start, import and
/// open them.
enum ThemeCommands {
    static func items(_ services: Services) -> [Item] {
        [
            Item(id: "system.theme", title: "Theme", subtitle: "Switch hop's look",
                 aliases: ["appearance", "colors", "dark mode", "light mode", "custom theme"],
                 icon: .tile("paintpalette.fill", Theme.chart5), accessory: "Command",
                 actions: [Action(title: "Choose Theme", symbol: "paintpalette") { .push(ThemeMode(services: services)) }],
                 pushesMode: true),
        ]
    }
}

final class ThemeMode: Mode {
    let title: String? = "Theme"
    let placeholder = "Search themes…"
    private let services: Services

    init(services: Services) { self.services = services }

    private var folder: URL { CustomThemes.folder(beside: services.settings.url) }

    /// Leaving without picking goes back to the saved theme.
    func didExit() { services.previewTheme?(services.settings.data.general.theme) }

    func selectionDidChange(_ item: Item?) {
        guard let id = item?.id, id.hasPrefix("theme.") else { return }
        services.previewTheme?(Theme.Name(rawValue: String(id.dropFirst("theme.".count))))
    }

    func sections(for query: String) -> [ResultSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let current = services.settings.data.general.theme
        func matches(_ text: String...) -> Bool { q.isEmpty || text.contains { $0.lowercased().contains(q) } }

        let builtIn = Theme.Name.builtIn.compactMap { name -> Item? in
            let spec = Theme.spec(name)
            guard matches(spec.label, name.rawValue) else { return nil }
            return item(name, spec, current: current)
        }
        let custom = Theme.custom.compactMap { name, spec -> Item? in
            guard matches(spec.label, name.rawValue, "custom") else { return nil }
            return item(name, spec, current: current)
        }
        let tools = [
            Item(id: "themes.new", title: "New Theme", subtitle: "Start one from \(Theme.spec(current).label) and open it in your editor",
                 aliases: ["create", "custom", "make"], icon: .tile("plus", Theme.chart1), accessory: "Command",
                 actions: [Action(title: "New Theme", symbol: "plus") { [services, folder] in
                     Self.create(from: current, in: folder, services: services)
                 }], tracksFrecency: false),
            Item(id: "themes.import", title: "Import Theme…", subtitle: "Add .json5 themes and their fonts (.ttf, .otf)",
                 aliases: ["upload", "add", "custom"], icon: .tile("square.and.arrow.down", Theme.chart3), accessory: "Command",
                 actions: [Action(title: "Choose Files…", symbol: "square.and.arrow.down") { [services, folder] in
                     DispatchQueue.main.async { Self.importThemes(into: folder, services: services) }
                     return .dismiss
                 }], tracksFrecency: false),
            Item(id: "themes.folder", title: "Open Themes Folder", subtitle: "~/.config/hop/themes",
                 aliases: ["custom", "reveal"], icon: .tile("folder.fill", Theme.chart2), accessory: "Command",
                 actions: [Action(title: "Open in Finder", symbol: "folder") { [folder] in
                     try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                     NSWorkspace.shared.open(folder)
                     return .dismiss
                 }], tracksFrecency: false),
        ].filter { q.isEmpty || matches($0.title) || $0.aliases.contains { $0.contains(q) } || "theme".contains(q) }

        return [
            ResultSection(title: nil, items: builtIn),
            ResultSection(title: "Your Themes", items: custom),
            ResultSection(title: "Make Your Own", items: tools),
        ].filter { !$0.items.isEmpty }
    }

    private func item(_ name: Theme.Name, _ spec: Theme.Spec, current: Theme.Name) -> Item {
        var actions = [Action(title: "Use Theme", symbol: "paintpalette") { [services] in
            Self.apply(name, services: services)
        }]
        if let file = spec.file {
            actions.append(Action(title: "Edit Theme File", symbol: "pencil") {
                ConfigOpener.open(file)
                return .dismiss
            })
            actions.append(Action(title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
                return .dismiss
            })
        }
        let tone = spec.light ? "Light" : "Dark"
        return Item(id: "theme.\(name.rawValue)", title: spec.label, subtitle: spec.description,
                    icon: .tile(spec.light ? "sun.max.fill" : "moon.fill", spec.palette.primary),
                    accessory: name.isBuiltIn ? tone : "Custom · \(tone)",
                    actions: actions,
                    tracksFrecency: false,
                    chip: name == current ? Chip(text: "Current", tone: .good) : nil)
    }

    private static func apply(_ name: Theme.Name, services: Services) -> ActionResult {
        let settings = services.settings
        if settings.data.general.theme == name { return .dismiss }
        guard settings.update(["general", "theme"], to: ConfigEdit.literal(name.rawValue))
        else { return .failWithHUD("Could not write the theme to the config") }
        return .dismissWithHUD("Theme: \(Theme.spec(name).label)")
    }

    private static func create(from name: Theme.Name, in folder: URL, services: Services) -> ActionResult {
        do {
            let url = try CustomThemes.create(in: folder, from: name)
            services.reloadThemes?()
            ConfigOpener.open(url)
            return .dismissWithHUD("New theme: \(url.lastPathComponent)")
        } catch {
            return .failWithHUD("Could not create the theme: \(error.localizedDescription)")
        }
    }

    /// An open panel for theme and font files; the first theme imported becomes the one in use.
    private static func importThemes(into folder: URL, services: Services) {
        let panel = NSOpenPanel()
        panel.title = "Import Theme"
        panel.message = "Choose hop themes (.json5) and the fonts they use (.ttf, .otf)."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (CustomThemes.extensions.union(CustomThemes.fontExtensions))
            .compactMap { UTType(filenameExtension: $0) }
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let added = try CustomThemes.importFiles(panel.urls, into: folder)
            services.reloadThemes?()
            guard let first = added.first else {
                HUD.shared.show("Fonts imported")
                return
            }
            if services.settings.update(["general", "theme"], to: ConfigEdit.literal(first.rawValue)) {
                HUD.shared.show("Theme: \(Theme.spec(first).label)")
            } else {
                HUD.shared.fail("Imported, but could not write the theme to the config")
            }
        } catch {
            HUD.shared.fail(error.localizedDescription)
        }
    }
}
