import CryptoKit
import Foundation
import os

/// Installs plugins from GitHub releases into Application Support/Plugins/<id>.
///
/// A plugin repository publishes a release with an asset named `*.hopplugin.zip`: a folder
/// (or the archive root) with `plugin.json5` and the program it names in `entry`.
nonisolated enum PluginInstaller {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case badLink(String)
        case github(String)
        case noAsset(String)
        case archive(String)
        case manifest(String)
        case tooOld(needs: String)

        var description: String {
            switch self {
            case .badLink(let s): "not a GitHub repository link: \(s)"
            case .github(let s): "GitHub: \(s)"
            case .noAsset(let tag): "release \(tag) has no .hopplugin.zip asset"
            case .archive(let s): "archive: \(s)"
            case .manifest(let s): "plugin.json5: \(s)"
            case .tooOld(let needs): "needs hop \(needs) or newer"
            }
        }
    }

    /// "owner/repo" and an optional release tag.
    struct Source: Equatable, Sendable {
        var owner: String
        var repo: String
        var tag: String?
        var repository: String { "\(owner)/\(repo)" }
    }

    /// A downloaded, checked plugin waiting for the user's yes.
    struct Staged: Sendable {
        var manifest: PluginManifest
        var record: PluginInstallRecord
        /// The folder holding plugin.json5, inside a temporary directory.
        var folder: URL
        var temporary: URL
    }

    static var pluginsDir: URL { AppPaths.file("Plugins") }
    /// hop's list of reviewed plugins: { "<id>": { "repository": "owner/repo", "sha256": ["…"] } }.
    static let indexURL = URL(string: "https://raw.githubusercontent.com/pseudobun/hop-plugins/main/index.json")!

    // MARK: Links

    /// `github.com/o/r`, `https://github.com/o/r(.git)`, `o/r`, each optionally `@tag`.
    static func parse(_ link: String) throws -> Source {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var tag: String?
        if let at = text.lastIndex(of: "@"), !text[text.index(after: at)...].contains("/") {
            tag = String(text[text.index(after: at)...])
            text = String(text[..<at])
        }
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasPrefix("github.com/") { text.removeFirst("github.com/".count) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        let name = /[A-Za-z0-9_.-]+/
        // github.com/o/r/releases/tag/v1 → that tag.
        if parts.count == 5, parts[2] == "releases", parts[3] == "tag", tag == nil { tag = String(parts[4]) }
        guard parts.count == 2 || parts.count == 5, parts[0].wholeMatch(of: name) != nil, parts[1].wholeMatch(of: name) != nil,
              tag.map({ !$0.isEmpty && !$0.contains("/") }) ?? true else { throw Failure.badLink(link) }
        return Source(owner: String(parts[0]), repo: String(parts[1]), tag: tag)
    }

    // MARK: Download

    struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        var tag_name: String
        var assets: [Asset]
    }

    /// The release's plugin archive: `*.hopplugin.zip`, an arm64 or universal one first.
    static func asset(in release: Release) -> Release.Asset? {
        let plugins = release.assets.filter { $0.name.lowercased().hasSuffix(".hopplugin.zip") }
        return plugins.first { $0.name.contains("arm64") || $0.name.contains("universal") } ?? plugins.first
    }

    static func download(_ source: Source, session: URLSession = .shared) async throws -> Staged {
        let api = source.tag.map { "https://api.github.com/repos/\(source.repository)/releases/tags/\($0)" }
            ?? "https://api.github.com/repos/\(source.repository)/releases/latest"
        var request = URLRequest(url: URL(string: api)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("hop-plugin-installer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.github("no release found for \(source.repository)\(source.tag.map { " @\($0)" } ?? "")")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = asset(in: release) else { throw Failure.noAsset(release.tag_name) }
        let (file, fileResponse) = try await session.download(from: asset.browser_download_url)
        guard (fileResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.github("could not download \(asset.name)") }
        let archive = try Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        let staged = try stage(archive: archive, source: source, tag: release.tag_name)
        var record = staged.record
        record.verified = await isListed(id: staged.manifest.id, repository: source.repository, sha256: record.sha256, session: session)
        return Staged(manifest: staged.manifest, record: record, folder: staged.folder, temporary: staged.temporary)
    }

    /// A `.hopplugin.zip` on disk: for plugin authors trying a build before releasing it.
    static func localArchive(_ text: String) -> URL? {
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines).expandingTilde
        guard path.lowercased().hasSuffix(".hopplugin.zip"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func stageLocal(_ archive: URL) throws -> Staged {
        let data = try Data(contentsOf: archive)
        let source = Source(owner: "local", repo: archive.lastPathComponent)
        var staged = try stage(archive: data, source: source, tag: "local")
        staged.record.repository = "local file \(archive.lastPathComponent)"
        staged.record.tag = staged.manifest.version
        return staged
    }

    /// A GitHub link or a local archive, downloaded and checked.
    static func fetch(_ link: String) async throws -> Staged {
        if let archive = localArchive(link) { return try stageLocal(archive) }
        return try await download(parse(link))
    }

    /// Unpacks and checks an archive in a fresh temporary folder.
    static func stage(archive: Data, source: Source, tag: String) throws -> Staged {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appending(path: "hop-plugin-\(UUID().uuidString)")
        let zip = temporary.appending(path: "plugin.zip"), out = temporary.appending(path: "unpacked")
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try archive.write(to: zip)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, out.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw Failure.archive("not a zip archive") }
            let folder = try pluginFolder(in: out)
            let manifest: PluginManifest
            do {
                manifest = try PluginManifest.decode(Data(contentsOf: folder.appending(path: "plugin.json5")))
            } catch let problem as PluginManifest.Problem {
                throw Failure.manifest(problem.description)
            } catch {
                throw Failure.manifest("\(error)")
            }
            if let needs = manifest.hop, isOlder(AppPaths.version, than: needs) { throw Failure.tooOld(needs: needs) }
            let entry = folder.appending(path: manifest.entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), !isDir.boolValue else {
                throw Failure.manifest("entry \(manifest.entry) is not in the archive")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
            let hash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            let record = PluginInstallRecord(repository: source.repository, tag: tag, sha256: hash, installedAt: Date())
            return Staged(manifest: manifest, record: record, folder: folder, temporary: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// The folder with plugin.json5: the archive root or its only folder. Links are refused,
    /// so nothing in the archive can point outside it.
    static func pluginFolder(in root: URL) throws -> URL {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw Failure.archive("empty")
        }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw Failure.archive("contains a symbolic link (\(url.lastPathComponent))")
        }
        if fm.fileExists(atPath: root.appending(path: "plugin.json5").path) { return root }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, fm.fileExists(atPath: children[0].appending(path: "plugin.json5").path) { return children[0] }
        throw Failure.archive("no plugin.json5 at its root")
    }

    /// Whether hop's index lists this plugin from this repository with this archive.
    static func isListed(id: String, repository: String, sha256: String, session: URLSession) async -> Bool {
        guard let (data, response) = try? await session.data(from: indexURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let index = try? JSONDecoder().decode(JSONValue.self, from: data),
              let entry = index[id] else { return false }
        return entry["repository"]?.string?.lowercased() == repository.lowercased()
            && (entry["sha256"]?.strings ?? []).contains(sha256)
    }

    /// "0.1.0" < "0.2.0"; a pre-release part ("-beta.5") is ignored.
    static func isOlder(_ version: String, than required: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(version), b = parts(required)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: Install and remove

    /// Moves a staged plugin into place, replacing an older copy of the same id.
    static func commit(_ staged: Staged) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staged.temporary) }
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let target = pluginsDir.appending(path: staged.manifest.id)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staged.folder, to: target)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(staged.record).write(to: target.appending(path: "install.json"))
        return target
    }

    static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.temporary)
    }

    static func remove(id: String) throws {
        guard id.wholeMatch(of: /[a-z0-9.-]+/) != nil else { throw Failure.manifest("bad id \(id)") }
        let target = pluginsDir.appending(path: id)
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.manifest("\(id) is not installed") }
        try FileManager.default.removeItem(at: target)
        Keychain.deleteAll(service: ExternalPlugin.keychainService(id))
    }
}

/// The plugins installed from GitHub, read at launch and after `hop plugin install`.
enum InstalledPlugins {
    struct Entry {
        var manifest: PluginManifest
        var directory: URL
        var record: PluginInstallRecord?
    }

    static func entries(in dir: URL = PluginInstaller.pluginsDir) -> [Entry] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            do {
                let manifest = try PluginManifest.decode(Data(contentsOf: folder.appending(path: "plugin.json5")))
                guard manifest.id == folder.lastPathComponent else {
                    Log.plugin.error("plugins: \(folder.lastPathComponent, privacy: .public) holds \(manifest.id, privacy: .public); skipped")
                    return nil
                }
                let record = (try? Data(contentsOf: folder.appending(path: "install.json")))
                    .flatMap { try? decoder.decode(PluginInstallRecord.self, from: $0) }
                return Entry(manifest: manifest, directory: folder, record: record)
            } catch {
                Log.plugin.error("plugins: \(folder.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    static func load() -> [any HopPlugin] {
        entries().map { ExternalPlugin(manifest: $0.manifest, directory: $0.directory, record: $0.record) }
    }
}
