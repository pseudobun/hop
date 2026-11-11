import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey`: no Accessibility or Input Monitoring needed.
/// Each instance owns one hotkey; handlers pass on presses that are not theirs.
final class GlobalHotkey {
    private static var nextID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.onPress = onPress
    }

    /// Default ⌘Space.
    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey)) -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == GlobalHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let pressedID = pressed.id
            return MainActor.assumeIsolated {
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                guard pressedID == hotkey.id else { return OSStatus(eventNotHandledErr) }
                hotkey.onPress()
                return noErr
            }
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        let hotKeyID = EventHotKeyID(signature: GlobalHotkey.signature, id: id)
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private nonisolated static let signature = OSType(0x686F7021) // 'hop!'
}
