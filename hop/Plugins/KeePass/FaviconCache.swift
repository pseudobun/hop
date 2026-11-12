import AppKit

/// Site icons for KeePass entries, fetched straight from each site (no third-party
/// favicon service learns which sites you have accounts on) and cached on disk.
final class FaviconCache {
    static let shared = FaviconCache()

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: AppPaths.bundleID, directoryHint: .isDirectory)
            .appending(path: "favicons", directoryHint: .isDirectory)
    }()
    private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    private var inFlight: Set<String> = []
    private var failed: [String: Date] = [:]
    private let maxAge: TimeInterval = 30 * 86_400
    private let retryFailedAfter: TimeInterval = 7 * 86_400
    private let maxConcurrent = 6
    /// Called (coalesced) when new icons arrived.
    var onUpdate: (() -> Void)?
    private var updateScheduled = false

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()

    static func host(of url: String) -> String? {
        let s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let withScheme = s.contains("://") ? s : "https://" + s
        guard let u = URL(string: withScheme), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let h = u.host?.lowercased(), h.contains(".") else { return nil }
        return h
    }

    /// Cached icon, or nil while it is being fetched (`onUpdate` fires when it lands).
    func icon(for host: String) -> NSImage? {
        if let img = memory.object(forKey: host as NSString) { return img }
        let file = dir.appending(path: host + ".png")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           let img = NSImage(contentsOf: file) {
            img.size = NSSize(width: 22, height: 22)
            memory.setObject(img, forKey: host as NSString)
            if Date().timeIntervalSince(modified) > maxAge { fetch(host) }
            return img
        }
        fetch(host)
        return nil
    }

    private func fetch(_ host: String) {
        guard !inFlight.contains(host), inFlight.count < maxConcurrent else { return }
        if let f = failed[host], Date().timeIntervalSince(f) < retryFailedAfter { return }
        inFlight.insert(host)
        let session = session, dir = dir
        Task {
            let data = await Self.download(host, session: session)
            inFlight.remove(host)
            guard let data, let img = NSImage(data: data), img.isValid, img.size.width >= 8 else {
                failed[host] = Date()
                return
            }
            if let png = Self.png(img) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? png.write(to: dir.appending(path: host + ".png"), options: .atomic)
            }
            img.size = NSSize(width: 22, height: 22)
            memory.setObject(img, forKey: host as NSString)
            scheduleUpdate()
        }
    }

    @concurrent
    private static func download(_ host: String, session: URLSession) async -> Data? {
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "https://\(host)\(path)") else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 64,
                  !(http.mimeType ?? "").contains("html")
            else { continue }
            return data
        }
        return nil
    }

    private static func png(_ img: NSImage) -> Data? {
        let side: CGFloat = 64
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            updateScheduled = false
            onUpdate?()
        }
    }
}
