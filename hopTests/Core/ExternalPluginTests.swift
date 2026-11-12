import Foundation
import Testing
@testable import hop

/// Plugins installed from GitHub: manifest, protocol, installer and a real child process.
struct PluginManifestTests {
    static let manifest = """
    // comments are fine
    {
      id: "dev.you.thing", name: "Thing", version: "1.2.0", entry: "bin/thing",
      commands: [
        { id: "list", title: "Things", prefix: "th " },
        { id: "sync", title: "Sync", kind: "background", interval: "15m" },
      ],
      preferences: [
        { id: "token", title: "Token", type: "secret" },
        { id: "max", title: "At most", type: "number", default: 5, hidden: true },
      ],
      permissions: { network: ["api.thing.dev"], clipboard: "write" },
    }
    """

    @Test func decodesWithDefaults() throws {
        let m = try PluginManifest.decode(Data(Self.manifest.utf8))
        #expect(m.id == "dev.you.thing" && m.commands.count == 2 && m.commands[0].kind == .view)
        #expect(m.commands[1].kind == .background && PluginManifest.seconds(m.commands[1].interval) == 900)
        #expect(m.preferences[1].default == .number(5) && m.preferences[1].hidden)
        #expect(m.permissions.lines == ["Network: api.thing.dev", "Clipboard: write"])
        #expect(m.symbol == "puzzlepiece.extension.fill")
    }

    @Test func rejectsWhatHopCannotTrust() {
        func problem(_ text: String) -> Bool { (try? PluginManifest.decode(Data(text.utf8))) == nil }
        #expect(problem(#"{ id: "Thing", name: "T", version: "1", entry: "x" }"#))
        #expect(problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "../x" }"#))
        #expect(problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "/bin/sh" }"#))
        #expect(problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "x", commands: [{ id: "a", title: "A" }, { id: "a", title: "B" }] }"#))
        #expect(problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "x", commands: [{ id: "a", title: "A", kind: "background" }] }"#))
        #expect(problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "x", preferences: [{ id: "enabled", title: "On" }] }"#))
        #expect(!problem(#"{ id: "dev.you.thing", name: "T", version: "1", entry: "x" }"#))
    }

    @Test func settingsComeFromPreferences() throws {
        let m = try PluginManifest.decode(Data(Self.manifest.utf8))
        let plugin = ExternalPlugin(manifest: m, directory: URL(fileURLWithPath: "/tmp"), record: nil)
        #expect(plugin.info.tier == .community && plugin.info.category == .installed && plugin.info.enabledPath == nil)
        let fields = plugin.settings.flatMap(\.rows).compactMap { if case .field(let f) = $0 { f } else { nil } }
        #expect(fields.map(\.path) == [["plugins", "dev.you.thing", "token"], ["plugins", "dev.you.thing", "max"]])
        if case .secret(let service, let account) = fields[0].kind {
            #expect(service.hasSuffix(".plugin.dev.you.thing") && account == "token")
        } else { Issue.record("token is not a secret field") }
        #expect(fields[1].hidden && fields[1].fallback as? Int == 5)
        // Defaults reach the program; unset secrets do not.
        #expect(plugin.preferences(HopConfig()) == ["max": .number(5)])
    }
}

struct PluginProtocolTests {
    @Test func responsesDecodeWithShorthands() throws {
        let text = #"""
        { "view": { "title": "T", "items": [ { "id": "a", "title": "A", "actions": [ { "title": "Copy", "type": "copy", "value": "x" } ] } ],
                    "sections": [ { "title": "More", "items": [ { "id": "b", "title": "B" } ] } ] },
          "hud": { "text": "hi", "style": "warn" } }
        """#
        let r = try JSONDecoder().decode(PluginProtocol.Response.self, from: Data(text.utf8))
        let view = try #require(r.view)
        #expect(view.type == .list && view.filtering == .hop)
        #expect(view.sections.map(\.title) == [nil, "More"])
        #expect(view.sections[0].items[0].actions[0].type == .copy)
        #expect(view.sections[1].items[0].actions.isEmpty)
        #expect(r.hud == PluginProtocol.HUDMessage(text: "hi", style: .warn))
    }

    @Test func requestsEncodeAsJSONRPC() throws {
        let data = try JSONEncoder().encode(PluginProtocol.Request(id: 7, method: "run", params: PluginProtocol.Run(command: "list")))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["jsonrpc"]?.string == "2.0" && json["id"]?.int == 7 && json["method"]?.string == "run")
        #expect(json["params"]?["command"]?.string == "list")
    }
}

struct PluginInstallerTests {
    @Test func parsesGitHubLinks() throws {
        let plain = PluginInstaller.Source(owner: "you", repo: "hop-thing")
        #expect(try PluginInstaller.parse("you/hop-thing") == plain)
        #expect(try PluginInstaller.parse("github.com/you/hop-thing") == plain)
        #expect(try PluginInstaller.parse("https://github.com/you/hop-thing.git") == plain)
        #expect(try PluginInstaller.parse(" https://www.github.com/you/hop-thing ").repository == "you/hop-thing")
        #expect(try PluginInstaller.parse("you/hop-thing@v1.2").tag == "v1.2")
        #expect(try PluginInstaller.parse("https://github.com/you/hop-thing/releases/tag/v2").tag == "v2")
        for bad in ["", "you", "https://gitlab.com/you/x/y", "you/x/y", "you/x@", "../x/y z"] {
            #expect(throws: PluginInstaller.Failure.self, "\(bad)") { try PluginInstaller.parse(bad) }
        }
    }

    @Test func picksThePluginAsset() {
        func asset(_ name: String) -> PluginInstaller.Release.Asset {
            .init(name: name, browser_download_url: URL(string: "https://x/\(name)")!)
        }
        let release = PluginInstaller.Release(tag_name: "v1", assets: [asset("src.zip"), asset("thing-x86.hopplugin.zip"), asset("thing-arm64.hopplugin.zip")])
        #expect(PluginInstaller.asset(in: release)?.name == "thing-arm64.hopplugin.zip")
        #expect(PluginInstaller.asset(in: .init(tag_name: "v1", assets: [asset("src.zip")])) == nil)
    }

    @Test func comparesVersions() {
        #expect(PluginInstaller.isOlder("0.1.0", than: "0.2.0"))
        #expect(PluginInstaller.isOlder("0.1.0-beta.5", than: "0.1.1"))
        #expect(!PluginInstaller.isOlder("0.2.0", than: "0.2"))
        #expect(!PluginInstaller.isOlder("1.0.0", than: "0.9.9"))
    }

    /// A zip of `files` (path → contents) inside a folder named `root`.
    static func zip(_ files: [String: String], root: String = "dev.you.thing", link: (String, String)? = nil) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "hop-zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let top = dir.appending(path: root)
        for (path, text) in files {
            let url = top.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        if let (at, target) = link { try fm.createSymbolicLink(atPath: top.appending(path: at).path, withDestinationPath: target) }
        let out = dir.appending(path: "out.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", top.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: out)
    }

    static let goodManifest = #"{ id: "dev.you.thing", name: "Thing", version: "1.0.0", entry: "bin/thing" }"#
    static let source = PluginInstaller.Source(owner: "you", repo: "thing")

    @Test func stagesAGoodArchive() throws {
        let data = try Self.zip(["plugin.json5": Self.goodManifest, "bin/thing": "#!/bin/sh\n"])
        let staged = try PluginInstaller.stage(archive: data, source: Self.source, tag: "v1")
        defer { PluginInstaller.discard(staged) }
        #expect(staged.manifest.id == "dev.you.thing" && staged.record.repository == "you/thing" && staged.record.tag == "v1")
        #expect(staged.record.sha256.count == 64 && !staged.record.verified)
        #expect(FileManager.default.isExecutableFile(atPath: staged.folder.appending(path: "bin/thing").path))
    }

    @Test func refusesBadArchives() throws {
        func refused(_ data: Data) -> Bool {
            do {
                PluginInstaller.discard(try PluginInstaller.stage(archive: data, source: Self.source, tag: "v1"))
                return false
            } catch { return true }
        }
        #expect(refused(Data("not a zip".utf8)))
        #expect(refused(try Self.zip(["plugin.json5": Self.goodManifest])), "entry missing")
        #expect(refused(try Self.zip(["readme.md": "hi"])), "no manifest")
        #expect(refused(try Self.zip(["plugin.json5": Self.goodManifest, "bin/thing": "x"], link: ("bin/escape", "/etc/passwd"))), "link")
        let old = #"{ id: "dev.you.thing", name: "T", version: "1", entry: "bin/thing", hop: "99.0.0" }"#
        #expect(refused(try Self.zip(["plugin.json5": old, "bin/thing": "x"])), "needs a newer hop")
    }
}

/// A plugin program in sh: answers every request by its id, so hop's side runs for real.
@MainActor
struct PluginProcessTests {
    static let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
        *'"command":"fail"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"nope"}}\n' "$id" ;;
        *'"method":"run"'*)
          printf '{"jsonrpc":"2.0","method":"hud","params":{"text":"working"}}\n'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"view":{"items":[{"id":"a","title":"%s"}]}}}\n' "$id" "$HOP_PLUGIN_ID" ;;
        *'"method":"shutdown"'*) exit 0 ;;
      esac
    done
    """#

    func makeProcess() throws -> (PluginProcess, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appending(path: "plugin.sh")
        try Self.script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let process = PluginProcess(executable: exe, directory: dir, name: "test") {
            PluginProtocol.Initialize(hopVersion: "0", pluginID: "dev.test.sh", preferences: [:], dataDir: dir.path, appearance: "dark")
        }
        return (process, dir)
    }

    @Test func talksToARealProgram() async throws {
        let (process, dir) = try makeProcess()
        defer { process.stop(); try? FileManager.default.removeItem(at: dir) }
        var notes: [String] = []
        process.onNotification = { method, _ in notes.append(method) }
        let result = try await process.request("run", PluginProtocol.Run(command: "list"))
        #expect(process.isRunning)
        let response = try JSONDecoder().decode(PluginProtocol.Response.self, from: JSONEncoder().encode(result))
        #expect(response.view?.sections.first?.items.first?.title == "dev.test.sh")
        await #expect(throws: PluginProcess.Failure.self) {
            _ = try await process.request("run", PluginProtocol.Run(command: "fail"))
        }
        // The notification line came before the reply.
        #expect(notes == ["hud"])
        process.stop()
        #expect(!process.isRunning)
        // Starts again on the next request.
        _ = try await process.request("run", PluginProtocol.Run(command: "list"))
        #expect(process.isRunning)
    }

    @Test func aMissingProgramFailsCleanly() async throws {
        let process = PluginProcess(executable: URL(fileURLWithPath: "/nonexistent/plugin"), directory: URL(fileURLWithPath: "/tmp"), name: "x") {
            PluginProtocol.Initialize(hopVersion: "0", pluginID: "dev.x.y", preferences: [:], dataDir: "/tmp", appearance: "dark")
        }
        await #expect(throws: PluginProcess.Failure.self) {
            _ = try await process.request("run", PluginProtocol.Run(command: "list"))
        }
        #expect(!process.isRunning)
    }
}
