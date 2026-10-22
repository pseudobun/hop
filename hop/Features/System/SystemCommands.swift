import AppKit

/// Empty Trash, Clear Downloads and Uninstall Application.
enum SystemCommands {
    static func items(_ services: Services) -> [Item] {
        [
            Item(id: "system.emptyTrash", title: "Empty Trash", icon: .tile("trash.fill", Palette.neutral), accessory: "Command",
                 actions: [Action(title: "Empty Trash") { .push(emptyTrashMode()) }], pushesMode: true),
            Item(id: "system.clearDownloads", title: "Clear Downloads", subtitle: "Move everything in Downloads to Trash",
                 icon: .tile("arrow.down", Theme.info), accessory: "Command",
                 actions: [Action(title: "Clear Downloads") {
                     .push(clearDownloadsMode(URL(fileURLWithPath: services.settings.data.system.downloadsFolder.expandingTilde)))
                 }], pushesMode: true),
            Item(id: "system.killProcess", title: "Kill Process", subtitle: "Search running processes and quit or force-kill them",
                 icon: .tile("xmark.octagon.fill", Theme.destructive), accessory: "Command",
                 actions: [Action(title: "Show Processes") {
                     .push(KillProcessMode(sensitivity: services.settings.data.general.sensitivity))
                 }], pushesMode: true),
            Item(id: "system.uninstall", title: "Uninstall Application", icon: .tile("xmark.bin.fill", Theme.warn), accessory: "Command",
                 actions: [Action(title: "Choose Application") { .push(UninstallPickerMode(services: services)) }],
                 pushesMode: true),
        ]
    }

    static func emptyTrashMode() -> ConfirmMode {
        ConfirmMode(title: "Empty Trash", message: "Permanently erase the items in the Trash",
                    confirmTitle: "Empty Trash", symbol: "trash.fill", tint: Palette.neutral,
                    prepare: { mode in
                        let r = try? await AppleScript.run(#"tell application "Finder" to count items of trash"#)
                        let n = Int(r?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
                        if n == 0 { mode.update(message: "The Trash is already empty") }
                        else if n > 0 { mode.update(message: "Permanently erase \(n) item\(n == 1 ? "" : "s")") }
                    },
                    confirm: {
                        let r = try? await AppleScript.run(#"tell application "Finder" to empty trash"#)
                        return r?.ok == true ? .dismissWithHUD("Trash emptied") : .stayWithHUD("Could not empty the Trash")
                    })
    }

    static func clearDownloadsMode(_ dir: URL) -> ConfirmMode {
        var items: [URL] = []
        return ConfirmMode(title: "Clear Downloads", message: "Counting…", confirmTitle: "Move to Trash",
                           symbol: "arrow.down", tint: Theme.info,
                           prepare: { mode in
                               let (urls, bytes) = await DownloadsScanner.scan(dir)
                               items = urls
                               let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                               mode.update(message: urls.isEmpty ? "Downloads is already empty"
                                           : "Move \(urls.count) item\(urls.count == 1 ? "" : "s") (\(size)) to the Trash")
                           },
                           confirm: {
                               guard !items.isEmpty else { return .pop }
                               let failed = await DownloadsScanner.trash(items)
                               return failed == 0 ? .dismissWithHUD("Downloads cleared")
                                   : .dismissWithHUD("\(failed) item\(failed == 1 ? "" : "s") could not be moved")
                           })
    }
}

nonisolated enum DownloadsScanner {
    /// Top-level, non-hidden items and their allocated size.
    @concurrent static func scan(_ dir: URL) async -> ([URL], Int64) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return ([], 0) }
        return (urls, urls.reduce(0) { $0 + FileSize.allocated($1) })
    }

    @concurrent static func trash(_ urls: [URL]) async -> Int {
        var failed = 0
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed += 1 }
        }
        return failed
    }
}

nonisolated enum FileSize {
    /// Allocated size of a file or a directory tree.
    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
