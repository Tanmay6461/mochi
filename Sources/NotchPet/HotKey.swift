import Carbon.HIToolbox

/// A system-wide shortcut via Carbon's RegisterEventHotKey (needs no extra permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private static var handlers: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    /// keyCode is a virtual key code (e.g. kVK_ANSI_J); modifiers are Carbon flags (cmdKey | optionKey).
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        Self.installHandlerOnce()

        let id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = self
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E50_4554), id: id) // 'NPET'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?.action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
