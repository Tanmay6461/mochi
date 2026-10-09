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

    /// "ctrl+option+space" → (key code, Carbon modifiers). Accepts cmd/command, option/opt/alt,
    /// ctrl/control, shift, plus one key: a letter, a digit, or space. Nil for "" or anything unknown.
    static func parse(_ text: String) -> (keyCode: Int, modifiers: Int)? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var modifiers = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers |= cmdKey
            case "option", "opt", "alt": modifiers |= optionKey
            case "ctrl", "control": modifiers |= controlKey
            case "shift": modifiers |= shiftKey
            default: return nil
            }
        }
        guard modifiers != 0, let code = keyCodes[key] else { return nil } // a bare key would hijack typing
        return (code, modifiers)
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
    ]

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
