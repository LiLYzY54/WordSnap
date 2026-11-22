import AppKit
import SwiftUI

// MARK: - Root view (single glass piece: capsule that grows into a panel)

struct RootSearchView: View {

    @ObservedObject var model: SearchModel
    let onHeightChange: (CGFloat) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar

            if model.phase != .idle {
                resultSection
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { onHeightChange($0) }
        .onChange(of: model.selectAllToken) { _, _ in
            // 等字段编辑器（NSText）就位后全选：预填后直接输入即替换
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // Refocus the search field every time the panel is summoned.
            if (notification.object as? NSWindow)?.isKind(of: NSPanel.self) == true {
                focused = true
            }
        }
    }

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

                TextField("搜索", text: $model.searchText, prompt: Text("Type a word, leave a trace…").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium))
                    .focused($focused)
                    .onSubmit { Task { await model.lookup() } }
                    .onExitCommand { NotificationCenter.default.post(name: .wordSnapHidePanel, object: nil) }

            if model.phase == .loading {
                ProgressView()
                    .controlSize(.small)
            } else if !model.searchText.isEmpty {
                Button {
                    model.reset()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Result states

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-08-03" → "8月3日"；解析失败原样返回
    static func prettyDate(_ iso: String) -> String {
        guard let date = shortDateFormatter.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func reunionMessage(entry: WordEntry, previousDate: String) -> String {
        previousDate.isEmpty
            ? "\(entry.word) 已在词汇表里，又遇到它了"
            : "\(entry.word) · \(prettyDate(previousDate)) 存过，又遇到它了"
    }

    @ViewBuilder
    private var resultSection: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .loading:
            Text("正在查询…")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        case .loaded(let entry):
            resultCard(entry)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.red)
                if model.suggestions.isEmpty {
                    Text("修改关键词后回车重试")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 6) {
                        Text("你是不是想找：")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        ForEach(model.suggestions, id: \.self) { candidate in
                            Button(candidate) { model.lookupReplacement(candidate) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.gray.opacity(0.15), in: .capsule)
                        }
                    }
                }
            }
        case .saved(let total):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已保存 · 第 \(total) 个词")
                        .font(.system(size: 16, weight: .medium))
                }
                Button("撤销") { model.undoSave() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .help("移除刚写入的记录")
                if let error = model.undoError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        case .noteFailed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                HStack {
                    Button("重试词笔记") { model.retryNoteSave() }
                    if model.canUndoSave {
                        Button("撤销保存") { model.undoSave() }
                    }
                }
                if let error = model.undoError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                }
            }
        case .reunion(let entry, let previousDate):
            // 忘词恰恰是间隔重复的信号：把「报错」翻转成「重逢」
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                Text(Self.reunionMessage(entry: entry, previousDate: previousDate))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    // MARK: Result card

    private func resultCard(_ entry: WordEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.word)
                    .font(.system(size: 28, weight: .bold))
                if !entry.phonetic.isEmpty {
                    Text("/\(entry.phonetic.hasPrefix("/") ? String(entry.phonetic.dropFirst()) : entry.phonetic)")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Button {
                    Pronouncer.shared.play(entry.word)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("朗读")
                Spacer()
                saveButton
            }

            if !entry.partOfSpeech.isEmpty || !entry.meaning.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if !entry.partOfSpeech.isEmpty {
                        Text(entry.partOfSpeech)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.15), in: .rect(cornerRadius: 6))
                            .foregroundStyle(.blue)
                    }
                    Text(entry.meaning)
                        .font(.system(size: 17))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 柯林斯整句英文释义（如 "If you describe something as ephemeral, ..."）
            if !entry.englishDef.isEmpty {
                Text(entry.englishDef)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.example.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    Text(entry.example)
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var saveButton: some View {
        Button {
            model.save()
        } label: {
            Label("保存", systemImage: "square.and.arrow.down.fill")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.return, modifiers: .command)
    }
}
