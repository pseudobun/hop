#if DEBUG
import AppKit
import os
import ScreenCaptureKit

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
}
#endif
