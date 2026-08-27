import AppKit
import ServiceManagement

/// Menu bar item: the app's permanent "face" — summon the panel,
/// toggle launch-at-login, quit.
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem

    var onTogglePanel: (() -> Void)?

    init(onTogglePanel: @escaping () -> Void) {
        self.onTogglePanel = onTogglePanel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "character.magnify",
                accessibilityDescription: "WordSnap"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt every time the menu opens so the login-item checkmark is current.
    private func rebuildMenu() {
        let menu = NSMenu()

        let summon = NSMenuItem(
            title: "呼出查词面板",
            action: #selector(summonPanel),
            keyEquivalent: "l"
        )
        summon.keyEquivalentModifierMask = [.command]
        summon.target = self
        menu.addItem(summon)

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "登录时启动 WordSnap",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        login.state = isLoginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 WordSnap", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func summonPanel() {
        onTogglePanel?()
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("WordSnap: failed to toggle login item: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
