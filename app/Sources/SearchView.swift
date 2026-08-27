import AppKit
import SwiftUI

// MARK: - Phase

enum LookupPhase: Equatable {
    case idle
    case loading
    case loaded(WordEntry)
    case failed(String)
    /// 保存成功：total = 词表总数，streak = 连续天数
    case saved(total: Int, streak: Int)
    /// 重复保存：这个词之前已存过（重逢）
    case reunion(entry: WordEntry, previousDate: String)
}

// MARK: - Model

@MainActor
final class SearchModel: ObservableObject {

    @Published var searchText = ""
    @Published var phase: LookupPhase = .idle
    /// 全选信号：token 自增触发一次输入框全选（配合剪贴板预填）
    @Published var selectAllToken = 0
    private var lastPrefilledWord: String?

    /// ⌘L 呼出时若剪贴板正好是单个英文词，直接预填（回车即查）。
    /// 记忆上次预填词避免同一词反复出现；不清空剪贴板——那是有破坏性的。
    func prefillFromClipboard() {
        guard searchText.isEmpty,
              let raw = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let word = Self.clipboardWord(raw),
              word != lastPrefilledWord else { return }
        lastPrefilledWord = word
        searchText = word
        selectAllToken += 1
    }

    private static func clipboardWord(_ s: String) -> String? {
        guard s.count <= 40,
              let regex = try? NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z\-']*$"#),
              regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { return nil }
        return s
    }

    func lookup() async {
        let word = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        phase = .loading

        do {
            phase = .loaded(try await WordService.shared.lookup(word))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func save() {
        guard case .loaded(let entry) = phase else { return }
        do {
            let outcome = try WordService.shared.save(entry)
            if outcome.saved {
                phase = .saved(total: outcome.totalCount, streak: outcome.streakDays)
                scheduleAutoHide()
            } else {
                phase = .reunion(entry: entry,
                                 previousDate: outcome.existingDate ?? "")
                scheduleAutoHide()
            }
        } catch {
            phase = .failed("保存失败：\(error.localizedDescription)")
        }
    }

    private func scheduleAutoHide(seconds: TimeInterval = 1.4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.reset()
            NotificationCenter.default.post(name: .wordSnapHidePanel, object: nil)
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func reset() {
        searchText = ""
        phase = .idle
    }
}

extension Notification.Name {
    static let wordSnapHidePanel = Notification.Name("wordSnapHidePanel")
}

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
        .onChange(of: model.selectAllToken) { _ in
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

            TextField("Type a word, leave a trace…", text: $model.searchText)
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
                Text("修改关键词后回车重试")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        case .saved(let total, let streak):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(streak > 1 ? "已保存 · 第 \(total) 个词 · 连续第 \(streak) 天"
                                : "已保存 · 第 \(total) 个词")
                    .font(.system(size: 16, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
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
