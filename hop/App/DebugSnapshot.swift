#if DEBUG
import AppKit
import os
import ScreenCaptureKit
import VideoToolbox

/// Debug-only: writes a PNG of one of hop's own windows. Capturing the current
/// process's windows needs no Screen Recording permission.
enum DebugSnapshot {
    /// A full-screen wallpaper window under the launcher, so glass samples a real backdrop.
    static func showBackdrop(_ imagePath: String) -> NSWindow? {
        guard let screen = NSScreen.main, let image = NSImage(contentsOfFile: imagePath) else { return nil }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating
        w.isReleasedWhenClosed = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.orderFrontRegardless()
        return w
    }

    /// Draws a window's view tree without the window server (no Screen Recording needed);
    /// glass has no backdrop here, so a flat colour stands in for the desktop.
    static func render(_ window: NSWindow, to path: String) {
        guard let root = window.contentView else { return }
        let view = (root as? NSGlassEffectView)?.contentView ?? root
        guard let layer = view.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        ctx.cgContext.setFillColor(NSColor(srgbRed: 0.2, green: 0.25, blue: 0.4, alpha: 1).cgColor)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        ctx.cgContext.scaleBy(x: 2, y: 2)
        layer.render(in: ctx.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Captures the screen region around `window` with only hop's windows composited.
    static func captureRegion(around window: NSWindow, padding: CGFloat, to path: String) async {
        do {
            let own = try await SCShareableContent.currentProcess
            var displays = own.displays
            if displays.isEmpty { displays = (try? await SCShareableContent.current)?.displays ?? [] }
            guard let display = displays.first else {
                Log.app.error("DebugSnapshot: no display")
                return
            }
            let filter = SCContentFilter(display: display, including: own.windows)
            let config = SCStreamConfiguration()
            let screenHeight = NSScreen.main?.frame.height ?? CGFloat(display.height)
            let f = window.frame.insetBy(dx: -padding, dy: -padding)
            config.sourceRect = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
            let scale = window.backingScaleFactor
            config.width = Int(f.width * scale)
            config.height = Int(f.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.app.error("DebugSnapshot region failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func capture(_ window: NSWindow, to path: String) async {
        do {
            let own = try await SCShareableContent.currentProcess
            guard let scWindow = own.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.app.error("DebugSnapshot: window not shareable")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(scWindow.frame.width * window.backingScaleFactor)
            config.height = Int(scWindow.frame.height * window.backingScaleFactor)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.app.error("DebugSnapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records the screen region `rect` (AppKit coordinates) with only hop's windows composited,
    /// every display frame for `seconds` after `action` runs, as numbered PNGs in `dir`: what an
    /// entrance or exit really looks like, frame by frame.
    static func recordFrames(_ rect: NSRect, seconds: Double, to dir: String, action: @escaping () -> Void) async {
        do {
            let own = try await SCShareableContent.currentProcess
            var displays = own.displays
            if displays.isEmpty { displays = (try? await SCShareableContent.current)?.displays ?? [] }
            guard let display = displays.first else { return }
            let filter = SCContentFilter(display: display, including: own.windows)
            let config = SCStreamConfiguration()
            let screenHeight = NSScreen.main?.frame.height ?? CGFloat(display.height)
            config.sourceRect = CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
            config.width = Int(rect.width)
            config.height = Int(rect.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.showsCursor = false
            config.queueDepth = 8
            let sink = FrameSink()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            try? await Task.sleep(for: .milliseconds(300))
            sink.start = CACurrentMediaTime()
            action()
            try? await Task.sleep(for: .seconds(seconds))
            try await stream.stopCapture()
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (i, frame) in sink.frames.enumerated() {
                let rep = NSBitmapImageRep(cgImage: frame.image)
                let name = String(format: "%@/%02d-%03dms.png", dir, i, Int((frame.time - sink.start) * 1000))
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
            }
        } catch {
            Log.app.error("DebugSnapshot frames failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "hop.debug.frames")
        private let lock = NSLock()
        private var stored: [(time: CFTimeInterval, image: CGImage)] = []
        var start: CFTimeInterval = .infinity
        var frames: [(time: CFTimeInterval, image: CGImage)] { lock.withLock { stored } }

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let pixels = buffer.imageBuffer else { return }
            // Only complete frames (idle ones repeat the last).
            if let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
               let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
            let now = CACurrentMediaTime()
            guard now >= start else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            // A copy: the stream reuses a handful of buffers and stops while we hold them.
            guard let image, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let copy = ctx.makeImage() { lock.withLock { stored.append((now, copy)) } }
        }
    }
}
#endif
