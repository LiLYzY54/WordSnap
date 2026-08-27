import AppKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {

    private var hotkeyManager: HotkeyManager!
    private var floatingWindow: FloatingWindow!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager = HotkeyManager()
        floatingWindow = FloatingWindow()

        // Register global hotkey: ⌘L
        hotkeyManager.register(key: .l, modifiers: [.command]) { [weak self] in
            DispatchQueue.main.async {
                self?.floatingWindow.toggle()
            }
        }

        // CLI login-item helpers: ./WordSnap --register-login-item
        // (works even if the menu bar icon isn't visible).
        let args = CommandLine.arguments
        if args.contains("--register-login-item") {
            try? SMAppService.mainApp.register()
        } else if args.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
        }

        // Menu bar item: the app's permanent home.
        statusBar = StatusBarController { [weak self] in
            self?.floatingWindow.toggle()
        }

        // 启动即预热直连：首次呼出查词就已接近即时
        WordService.YoudaoDirectClient.shared.warmUp()

        // Debug helper: WORDSNAP_AUTOSHOW=1 opens the panel on launch;
        // WORDSNAP_AUTOSHOW=lookup also runs a lookup for visual tests.
        if ProcessInfo.processInfo.environment["WORDSNAP_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.floatingWindow.toggle()
                if ProcessInfo.processInfo.environment["WORDSNAP_AUTOSHOW"] == "lookup" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.floatingWindow.debugLookup("hello")
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregisterAll()
    }
}
