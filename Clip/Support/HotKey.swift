import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Cocoa modifier flags.
struct HotKey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayString: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + HotKey.keyName(for: keyCode)
    }

    static let defaults: [HotKeyAction: HotKey] = [
        .captureArea: HotKey(keyCode: kVK_ANSI_4, modifiers: [.option, .shift]),
        .captureWindow: HotKey(keyCode: kVK_ANSI_5, modifiers: [.option, .shift]),
        .captureFullscreen: HotKey(keyCode: kVK_ANSI_3, modifiers: [.option, .shift]),
        .capturePreviousArea: HotKey(keyCode: kVK_ANSI_6, modifiers: [.option, .shift]),
        .openHistory: HotKey(keyCode: kVK_ANSI_H, modifiers: [.option, .shift]),
    ]

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: break
        }
        // Translate the key code through the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers global hot keys through Carbon's `RegisterEventHotKey`, which needs
/// no Accessibility permission and no third-party dependency.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var handlerInstalled = false
    var onTrigger: ((HotKeyAction) -> Void)?

    func register(_ hotKeys: [HotKeyAction: HotKey]) {
        installHandlerIfNeeded()
        unregisterAll()
        for (index, action) in HotKeyAction.allCases.enumerated() {
            guard let hotKey = hotKeys[action] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: id) // 'CLIP'
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[id] = (ref, action)
            } else {
                NSLog("Clip: failed to register hot key \(hotKey.displayString) for \(action.rawValue) (\(status))")
            }
        }
    }

    func unregisterAll() {
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        guard let action = registered[id]?.action else { return }
        onTrigger?(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.handle(id: id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
