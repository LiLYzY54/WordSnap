import AppKit
import Carbon

final class HotkeyManager {

    private var hotkeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var handlerInstalled = false

    enum KeyCode: UInt32 {
        case w = 13
        case l = 37
    }

    func register(key: KeyCode, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        self.handler = handler

        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x57534E50) // "WSNP"
        hotkeyID.id = 1

        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        let status = RegisterEventHotKey(
            key.rawValue,
            carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status != noErr {
            NSLog("Failed to register hotkey: \(status)")
        }

        installHandlerIfNeeded()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handler?()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        handlerInstalled = true
    }

    func unregisterAll() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }
}
