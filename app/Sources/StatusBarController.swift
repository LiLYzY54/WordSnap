import AppKit
import ServiceManagement
import SwiftUI

/// Menu bar item: the app's permanent "face" — summon the panel,
/// toggle launch-at-login, quit.
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem

    var onTogglePanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onLookupWord: ((String) -> Void)?

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

    // Rebuilt every time the menu opens so login-item checkmark / 今日一词
    // / heatmap are current. 填充传入的同一菜单，绝不替换 statusItem.menu
    //（替换会让菜单跟踪重启、点击穿透到第一项）。
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // 首项放禁用的标题：状态菜单在鼠标按下即开始跟踪，图标正下方就是
        // 第一项——快速点击时抬起会落在第一项上，禁用项保证绝不误触发
        //（此前「呼出查词面板」在第一位，点图标进设置常顺手把面板召唤出来）。
        let title = NSMenuItem(title: "WordSnap", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let summon = NSMenuItem(
            title: "呼出查词面板",
            action: #selector(summonPanel),
            keyEquivalent: "l"
        )
        summon.keyEquivalentModifierMask = [.command]
        summon.target = self
        menu.addItem(summon)

        menu.addItem(.separator())

        if let content = try? String(contentsOfFile: WordService.obsidianFile, encoding: .utf8) {
            // 今日一词：点击直接呼出面板查它
            if let daily = WordService.wordOfTheDay(in: content) {
                let dailyItem = NSMenuItem(
                    title: "📖 今日一词：\(daily.word) — \(daily.meaning)",
                    action: #selector(lookupTodayWord),
                    keyEquivalent: ""
                )
                dailyItem.target = self
                dailyItem.representedObject = daily.word
                menu.addItem(dailyItem)
                menu.addItem(.separator())
            }

            // 近 16 周热力图
            let heatmapItem = NSMenuItem()
            let hosting = NSHostingView(
                rootView: HeatmapView(counts: WordService.dateCounts(in: content)))
            hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 110)
            heatmapItem.view = hosting
            menu.addItem(heatmapItem)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

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
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func summonPanel() {
        onTogglePanel?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func lookupTodayWord(_ sender: NSMenuItem) {
        if let word = sender.representedObject as? String {
            onLookupWord?(word)
        }
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
