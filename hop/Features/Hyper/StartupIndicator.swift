import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Signals startup without changing Caps Lock's typing state or reading key events.
final class StartupIndicator {
    private var client: IOHIDEventSystemClient?
    private var services: [IOHIDServiceClient] = []
    private var animation: Task<Void, Never>?

    func start() {
        stop()
        // The passive client constructor and LED override are undocumented. Resolve
        // the constructor at runtime so an OS without it can simply skip the signal.
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "IOHIDEventSystemClientCreateWithType") else { return }
        typealias CreateClient = @convention(c) (CFAllocator?, UInt32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?
        let create = unsafeBitCast(symbol, to: CreateClient.self)
        guard let client = create(kCFAllocatorDefault, 2, nil)?.takeRetainedValue() else { return }
        self.client = client
        services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
        guard !services.isEmpty, setLED("Auto") else {
            stop()
            return
        }
        animation = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                for _ in 0..<5 {
                    guard self?.setLED("On") == true else { break }
                    try await Task.sleep(for: .milliseconds(300))
                    guard self?.setLED("Off") == true else { break }
                    try await Task.sleep(for: .milliseconds(300))
                }
            } catch { return } // stop() already restored Auto.
            self?.stop()
        }
    }

    func stop() {
        animation?.cancel()
        animation = nil
        // Restore system control, including any Caps Lock changes made while blinking.
        _ = setLED("Auto")
        services.removeAll()
        client = nil
    }

    @discardableResult
    private func setLED(_ state: String) -> Bool {
        var changed = false
        for service in services {
            if IOHIDServiceClientSetProperty(service, "HIDCapsLockLED" as CFString, state as CFString) {
                changed = true
            }
        }
        return changed
    }
}
