import Foundation
import Security
import os

/// The CLI ↔ running hop channel (`hop shelf`, `hop update`).
///
/// A Unix socket in hop's support folder (0700, socket 0600). The app answers only a peer that runs
/// as the same user and whose code satisfies hop's own designated requirement, which in practice is
/// the hop binary itself run as the CLI. Other processes (a script, another app, another user) can't
/// drive the running hop. The verbs stay narrow.
nonisolated enum HopIPC {
    struct Message: Codable, Sendable {
        enum Verb: String, Codable, Sendable { case shelfAdd, updateInstall, updateCheck, pluginsChanged }
        var verb: Verb
        var value: String?
        var paths: [String]?
    }

    struct Reply: Codable, Sendable {
        var ok: Bool
        var error: String?
        static let ok = Reply(ok: true)
        static func fail(_ e: String) -> Reply { Reply(ok: false, error: e) }
    }

    static var socketURL: URL { AppPaths.file("hop.sock") }
    static let maxMessage = 256 * 1024

    // MARK: Client

    /// Sends one message to the running hop and waits for its answer.
    static func send(_ message: Message) -> Reply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .fail("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        configure(fd)
        guard var addr = address(socketURL.path) else { return .fail("socket path too long") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .fail("hop is not running (or is older than this CLI)") }
        guard let data = try? JSONEncoder().encode(message), writeAll(fd, data) else { return .fail("could not reach hop") }
        shutdown(fd, SHUT_WR)
        guard let answer = readAll(fd, limit: 64 * 1024),
              let reply = try? JSONDecoder().decode(Reply.self, from: answer) else {
            return .fail("hop refused the request (only the hop CLI may talk to it)")
        }
        return reply
    }

    // MARK: Shared

    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return data }
            if n < 0 { return nil }
            data.append(buffer, count: n)
            if data.count > limit { return nil }
        }
    }

    // MARK: Peer check

    /// The peer runs as this user and its code satisfies hop's designated requirement.
    static func peerIsHop(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x006 /* LOCAL_PEERTOKEN */, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &peer) == errSecSuccess,
              let peer, let requirement = ownRequirement else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }

    /// hop's own designated requirement; nil (every peer refused) when hop isn't signed.
    nonisolated(unsafe) private static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()
}

/// The running hop's end of `HopIPC`.
nonisolated final class HopIPCServer: @unchecked Sendable {
    typealias Handler = @MainActor (HopIPC.Message) -> HopIPC.Reply

    private let queue = DispatchQueue(label: "hop.ipc")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: Handler
    /// Recent request times: more than `burst` in a second are refused.
    private var recent: [Date] = []
    private let burst = 10

    init(handler: @escaping Handler) { self.handler = handler }

    func start() {
        queue.async { self.listen() }
    }

    private func listen() {
        let path = HopIPC.socketURL.path
        let dir = HopIPC.socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            Log.app.error("ipc: support folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard var addr = HopIPC.address(path) else {
            Log.app.error("ipc: socket path too long: \(path, privacy: .public)")
            return
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            Log.app.error("ipc: listen failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        HopIPC.configure(client)
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(client, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len)
        guard HopIPC.peerIsHop(client) else {
            Log.app.error("ipc: refused a peer that is not hop (pid \(pid, privacy: .public))")
            return
        }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0) < 1 } + [now]
        let reply: HopIPC.Reply
        if recent.count > burst {
            reply = .fail("too many requests")
        } else if let data = HopIPC.readAll(client, limit: HopIPC.maxMessage),
                  let message = try? JSONDecoder().decode(HopIPC.Message.self, from: data) {
            Log.app.notice("ipc: \(message.verb.rawValue, privacy: .public) \(message.value ?? "", privacy: .public) from pid \(pid, privacy: .public)")
            reply = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(message) } }
        } else {
            reply = .fail("bad request")
        }
        if let data = try? JSONEncoder().encode(reply) { _ = HopIPC.writeAll(client, data) }
    }
}
