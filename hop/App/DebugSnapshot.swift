#if DEBUG
import AppKit
import os
import ScreenCaptureKit

/// Debug-only: writes a PNG of one of hop's own windows. Capturing the current
/// process's windows needs no Screen Recording permission.
enum DebugSnapshot {
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
