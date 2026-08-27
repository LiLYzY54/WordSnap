import AppKit
import Carbon
import SwiftUI

// MARK: - ViewModel

@MainActor
final class SettingsModel: ObservableObject {

    @Published var hotkeyDisplay: String = HotkeyManager.stored.display
    @Published var isRecording = false
    @Published var obsidianPath: String = WordService.obsidianFile

    var onStartRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
}

// MARK: - Root view

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingBlock(title: "全局快捷键") {
                HStack(spacing: 12) {
                    Text(model.hotkeyDisplay)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                    Button(model.isRecording ? "按下新快捷键…（Esc 取消）" : "录制…") {
                        model.isRecording ? model.onCancelRecording?() : model.onStartRecording?()
                    }
                    .disabled(model.isRecording)
                }
                Text("须包含 ⌘ / ⌃ / ⌥ 修饰键。默认 ⌘L；⌘L 与浏览器地址栏聚焦冲突，可在此换掉。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            settingBlock(title: "Obsidian 词汇表") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.obsidianPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("选择文件…") { pickObsidianFile() }
                }
                Text("表格与词笔记都写在该文件所在目录（笔记在其下 Vocabulary/ 子目录）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func settingBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func pickObsidianFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "选择 Obsidian 词汇表 Markdown 文件（不存在也可选目标目录中的任意 .md）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let json: [String: Any] = ["obsidianPath": url.path]
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wordsnap.json")
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: configURL)
        }
        WordService.refreshObsidianPath()
        model.obsidianPath = WordService.obsidianFile
    }
}

// MARK: - Window controller（录制用本地事件监听住在这里）

final class SettingsWindowController: NSWindowController {

    private let model = SettingsModel()
    private var keyMonitor: Any?
    private var onHotkeyChanged: ((HotkeyManager.Config) -> Void)?

    init(onHotkeyChanged: @escaping (HotkeyManager.Config) -> Void) {
        self.onHotkeyChanged = onHotkeyChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "WordSnap 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        model.onStartRecording = { [weak self] in self?.startRecording() }
        model.onCancelRecording = { [weak self] in self?.stopRecording() }
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.hotkeyDisplay = HotkeyManager.stored.display
        model.obsidianPath = WordService.obsidianFile
        // accessory 应用需要先激活才能把设置窗口带到前台（用户主动打开，可接受）
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Hotkey recording

    private func startRecording() {
        guard keyMonitor == nil else { return }
        model.isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Esc 取消；纯修饰键忽略
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            guard !flags.isEmpty, !Self.modifierKeyCodes.contains(UInt32(event.keyCode)) else {
                return nil // 录制中吞掉无效按键
            }
            let config = HotkeyManager.Config(keyCode: UInt32(event.keyCode), modifiers: flags)
            HotkeyManager.stored = config
            self.onHotkeyChanged?(config)
            self.model.hotkeyDisplay = config.display
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model.isRecording = false
    }

    private static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}
