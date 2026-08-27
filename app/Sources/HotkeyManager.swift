import AppKit
import Carbon

final class HotkeyManager {

    /// 可配置的全局热键（持久化于 UserDefaults）
    struct Config: Equatable {
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags

        static let `default` = Config(keyCode: 37, modifiers: [.command]) // ⌘L

        var display: String {
            var text = ""
            if modifiers.contains(.command) { text += "⌘" }
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            text += Self.keyNames[keyCode] ?? "Key\(keyCode)"
            return text
        }

        /// ANSI 键盘常用键码（字母/数字/少量符号），其余回退 Key<code>
        static let keyNames: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
            33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            49: "Space", 36: "Return", 53: "Esc", 123: "←", 124: "→",
        ]
    }

    private var hotkeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var handlerInstalled = false

    static var stored: Config {
        get {
            let defaults = UserDefaults.standard
            let code = UInt32(defaults.object(forKey: "hotkeyKeyCode") as? Int ?? Int(Config.default.keyCode))
            var modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotkeyModifiers")))
            modifiers = modifiers.intersection([.command, .control, .option, .shift])
            return Config(keyCode: code, modifiers: modifiers.isEmpty ? [.command] : modifiers)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(newValue.keyCode), forKey: "hotkeyKeyCode")
            defaults.set(Int(newValue.modifiers.rawValue), forKey: "hotkeyModifiers")
        }
    }

    func register(config: Config, handler: @escaping () -> Void) {
        self.handler = handler

        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x57534E50) // "WSNP"
        hotkeyID.id = 1

        var carbonModifiers: UInt32 = 0
        if config.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if config.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if config.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if config.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        let status = RegisterEventHotKey(
            config.keyCode,
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

    /// 换热键：注销旧的再注册新的（设置窗口实时生效）。
    func reregister(config: Config, handler: @escaping () -> Void) {
        unregisterAll()
        register(config: config, handler: handler)
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
