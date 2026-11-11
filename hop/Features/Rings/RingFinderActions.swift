import AppKit
import UniformTypeIdentifiers

/// Actions on what is selected in Finder (Finder Automation permission, like Empty Trash).
enum FinderActions {
    static func selection() async -> [URL]? {
        let source = """
        tell application "Finder"
          set out to ""
          repeat with i in (selection as alias list)
            set out to out & POSIX path of i & linefeed
          end repeat
          return out
        end tell
        """
        guard let r = try? await AppleScript.run(source), r.ok else { return nil }
        return r.out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    static func frontFolder() async -> URL? {
        let source = #"tell application "Finder" to if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)"#
        guard let r = try? await AppleScript.run(source), r.ok else { return nil }
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func run(_ id: String) async -> RingOutcome {
        if id == "new-folder" {
            return await RingRunner.script(#"tell application "Finder" to if (count of Finder windows) > 0 then select (make new folder at (target of front Finder window))"#)
        }
        if id == "open-terminal" {
            var dir = await selection().flatMap { $0.count == 1 && $0[0].hasDirectoryPath ? $0[0] : nil }
            if dir == nil { dir = await frontFolder() }
            guard let dir else { return .warn("Open a Finder window first") }
            return await RingRunner.run("/usr/bin/open", ["-a", "Terminal", dir.path])
        }
        guard let items = await selection() else { return .fail("Could not read Finder's selection") }
        guard !items.isEmpty else { return .warn("Select something in Finder first") }
        switch id {
        case "copy-path":
            Pasteboard.copy(items.map(\.path).joined(separator: "\n"))
            return .hud(items.count == 1 ? "Path copied" : "\(items.count) paths copied")
        case "copy-name":
            Pasteboard.copy(items.map(\.lastPathComponent).joined(separator: "\n"))
            return .hud("Name copied")
        case "copy-files":
            let pb = NSPasteboard.general
            pb.clearContents()
            return pb.writeObjects(items as [NSURL]) ? .hud("\(items.count) item\(items.count == 1 ? "" : "s") copied") : .fail("Could not copy")
        case "airdrop":
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items)
            else { return .fail("AirDrop cannot send these now") }
            NSApp.activate()
            service.perform(withItems: items)
            return .done
        case "move-to", "copy-to":
            return transfer(items, move: id == "move-to")
        case "compress":
            let first = items[0]
            let name = items.count == 1 ? first.lastPathComponent : "Archive"
            let out = uniqueURL(first.deletingLastPathComponent().appending(path: name + ".zip"))
            if items.count == 1 {
                return await RingRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            }
            // zip stores paths as given: run it in the folder so the archive holds just the names.
            _ = try? await ProcessRunner.run("/bin/sh", ["-c", "cd \"$0\" && /usr/bin/zip -r -q \"$@\"",
                                                         first.deletingLastPathComponent().path, out.path] + items.map(\.lastPathComponent),
                                             timeout: .seconds(600))
            return FileManager.default.fileExists(atPath: out.path) ? .hud("Compressed") : .fail("Could not compress")
        case "show-info":
            return await RingRunner.script(#"tell application "Finder" to repeat with i in (selection as alias list) to open information window of i"#)
        case "open-vscode":
            return await RingRunner.run("/usr/bin/open", ["-a", "Visual Studio Code"] + items.map(\.path))
        case "convert":
            guard items.count == 1, !items[0].hasDirectoryPath else { return .warn("Select one file to convert") }
            return FileConverter.fan(items[0])
        default:
            return .fail("Unknown Finder action")
        }
    }

    /// Moves or copies into a folder picked each time; nothing is replaced.
    static func transfer(_ items: [URL], move: Bool) -> RingOutcome {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = "Choose where to \(move ? "move" : "copy") \(items.count == 1 ? items[0].lastPathComponent : "\(items.count) items")"
        NSApp.activate()
        guard panel.runModal() == .OK, let dest = panel.url else { return .done }
        let fm = FileManager.default
        let names = items.map(\.lastPathComponent)
        if Set(names).count != names.count { return .fail("Two selected items share a name; nothing was \(move ? "moved" : "copied")") }
        if names.contains(where: { fm.fileExists(atPath: dest.appending(path: $0).path) }) {
            return .fail("An item with the same name is already there; nothing was \(move ? "moved" : "copied")")
        }
        if items.contains(where: { dest.path.hasPrefix($0.path + "/") || dest == $0 }) {
            return .fail("A folder cannot go inside itself")
        }
        var done = 0
        for item in items {
            do {
                if move { try fm.moveItem(at: item, to: dest.appending(path: item.lastPathComponent)) }
                else { try fm.copyItem(at: item, to: dest.appending(path: item.lastPathComponent)) }
                done += 1
            } catch {
                return .fail("\(done) done, then: \(error.localizedDescription)")
            }
        }
        return .hud("\(move ? "Moved" : "Copied") \(done) item\(done == 1 ? "" : "s")")
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        for n in 2...999 {
            let candidate = dir.appending(path: "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// "Convert": a fan of target formats for the selected file, made with tools macOS ships
/// (sips, afconvert, avconvert) or ffmpeg when it is installed. The new file lands next to the old.
enum FileConverter {
    struct Target {
        let label: String
        let ext: String
        let command: (URL, URL) -> (String, [String])
    }

    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func targets(for type: UTType) -> [Target] {
        var out: [Target] = []
        if type.conforms(to: .image) {
            for (label, ext, format) in [("PNG", "png", "png"), ("JPEG", "jpg", "jpeg"), ("HEIC", "heic", "heic"),
                                         ("TIFF", "tiff", "tiff"), ("PDF", "pdf", "pdf")] {
                out.append(Target(label: label, ext: ext) { i, o in ("/usr/bin/sips", ["-s", "format", format, i.path, "--out", o.path]) })
            }
            if let ffmpeg { out.append(Target(label: "WebP", ext: "webp") { i, o in (ffmpeg, ["-y", "-i", i.path, o.path]) }) }
        } else if type.conforms(to: .audio) {
            out.append(Target(label: "M4A", ext: "m4a") { i, o in ("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", i.path, o.path]) })
            out.append(Target(label: "WAV", ext: "wav") { i, o in ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", i.path, o.path]) })
            out.append(Target(label: "AIFF", ext: "aiff") { i, o in ("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI16", i.path, o.path]) })
            if let ffmpeg {
                out.append(Target(label: "MP3", ext: "mp3") { i, o in (ffmpeg, ["-y", "-i", i.path, "-q:a", "2", o.path]) })
                out.append(Target(label: "FLAC", ext: "flac") { i, o in (ffmpeg, ["-y", "-i", i.path, o.path]) })
            }
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            out.append(Target(label: "MP4", ext: "mp4") { i, o in
                ("/usr/bin/avconvert", ["--source", i.path, "--preset", "PresetHighestQuality", "--output", o.path, "--replace"])
            })
            out.append(Target(label: "MOV", ext: "mov") { i, o in
                ("/usr/bin/avconvert", ["--source", i.path, "--preset", "PresetHighestQuality", "--output", o.path, "--replace"])
            })
            out.append(Target(label: "Audio (M4A)", ext: "m4a") { i, o in
                ("/usr/bin/avconvert", ["--source", i.path, "--preset", "PresetAppleM4A", "--output", o.path, "--replace"])
            })
            if let ffmpeg {
                out.append(Target(label: "GIF", ext: "gif") { i, o in
                    (ffmpeg, ["-y", "-i", i.path, "-vf", "fps=12,scale=640:-1:flags=lanczos", o.path])
                })
                out.append(Target(label: "WebM", ext: "webm") { i, o in (ffmpeg, ["-y", "-i", i.path, o.path]) })
                out.append(Target(label: "MP3", ext: "mp3") { i, o in (ffmpeg, ["-y", "-i", i.path, "-vn", "-q:a", "2", o.path]) })
            }
        }
        return out
    }

    static func fan(_ file: URL) -> RingOutcome {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return .warn("hop can't convert this kind of file") }
        let current = file.pathExtension.lowercased()
        let options = targets(for: type).filter { $0.ext != current && !(current == "jpeg" && $0.ext == "jpg") }
        guard !options.isEmpty else { return .warn("hop can't convert this kind of file") }
        return .fan("Convert", options.prefix(8).map { target in
            RingNode(title: target.label, symbol: "arrow.triangle.2.circlepath", kind: .run(statsKey: "convert") { _ in
                await convert(file, to: target)
            })
        })
    }

    static func convert(_ file: URL, to target: Target) async -> RingOutcome {
        let out = FinderActions.uniqueURL(file.deletingPathExtension().appendingPathExtension(target.ext))
        let (exe, args) = target.command(file, out)
        HUD.shared.show("Converting to \(target.label)…", symbol: "arrow.triangle.2.circlepath")
        let r = try? await ProcessRunner.run(exe, args, timeout: .seconds(1800))
        guard r?.ok == true, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            return .fail("The conversion failed")
        }
        NSWorkspace.shared.activateFileViewerSelecting([out])
        return .hud("Saved \(out.lastPathComponent)")
    }
}
