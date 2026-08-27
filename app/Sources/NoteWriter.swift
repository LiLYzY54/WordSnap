import Foundation

/// 词笔记：Obsidian 管理端里「这个词的家」。表格是采集日志，笔记是本体。
///
/// - 路径：表格同目录的 `Vocabulary/<word>.md`
/// - 模板末尾的 `word::释义` 单行卡兼容 obsidian-spaced-repetition，
///   桌面与手机端可直接开背
/// - 已存在则绝不覆盖；「重逢」只在「我的痕迹」下追加一行
enum NoteWriter {

    // MARK: Path

    static func noteDirectory(tablePath: String = WordService.obsidianFile) -> String {
        NSString(string: tablePath).deletingLastPathComponent + "/Vocabulary"
    }

    static func notePath(for word: String, tablePath: String = WordService.obsidianFile) -> String {
        let sanitized = word.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return noteDirectory(tablePath: tablePath) + "/\(sanitized).md"
    }

    // MARK: Write

    /// 不存在则按模板创建。返回 true = 本次新建。
    @discardableResult
    static func writeIfMissing(_ entry: WordEntry, tablePath: String = WordService.obsidianFile) -> Bool {
        let path = notePath(for: entry.word, tablePath: tablePath)
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: noteDirectory(tablePath: tablePath), withIntermediateDirectories: true)
            try template(for: entry).write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("WordSnap [note] create failed for %@: %@", entry.word, String(describing: error))
            return false
        }
    }

    /// 「我的痕迹」下追加一行重逢记录；笔记不存在则先补建（此时无需追加）。
    static func appendEncounter(_ entry: WordEntry,
                                note: String = "在阅读中又遇到了它",
                                tablePath: String = WordService.obsidianFile) {
        let path = notePath(for: entry.word, tablePath: tablePath)
        if writeIfMissing(entry, tablePath: tablePath) { return }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard let markerRange = raw.range(of: "## 我的痕迹") else { return }

        // 插到标记行行尾之后，保持 flashcard 行留在文末
        let insertPoint = raw.range(of: "\n", range: markerRange.upperBound..<raw.endIndex)?
            .lowerBound ?? raw.endIndex
        var out = raw
        out.insert(contentsOf: "\n- \(entry.date) \(note)", at: insertPoint)
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 撤销窗口专用：删除本次保存新建的笔记（只对新建标记调用）。
    @discardableResult
    static func deleteNote(for word: String, tablePath: String = WordService.obsidianFile) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: notePath(for: word, tablePath: tablePath))
            return true
        } catch {
            return false
        }
    }

    // MARK: Template

    /// 柯林斯星级 "4" → "★★★★☆"
    static func stars(_ raw: String?) -> String {
        guard let level = Int(raw ?? ""), (1...5).contains(level) else { return "" }
        return String(repeating: "★", count: level) + String(repeating: "☆", count: 5 - level)
    }

    static func template(for entry: WordEntry) -> String {
        var phonetic = entry.phonetic
        if !phonetic.isEmpty && !phonetic.hasPrefix("/") { phonetic = "/\(phonetic)/" }

        let meanings = entry.meaning.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let meaningBlock = meanings.map { "- \($0)" }.joined(separator: "\n")

        var out = """
        ---
        word: \(entry.word)
        phonetic: \(phonetic)
        pos: \(entry.partOfSpeech)
        added: \(entry.date)
        source: \(entry.source)
        star: \(stars(entry.star))
        status: new
        tags: [vocabulary, flashcards]
        ---

        # \(entry.word)

        ## 释义
        \(meaningBlock)

        """
        if !entry.englishDef.isEmpty {
            out += "\n## 英文释义\n\(entry.englishDef)\n"
        }
        if !entry.example.isEmpty {
            out += "\n## 例句\n- \(entry.example)\n"
        }
        out += """

        ## 我的痕迹
        <!-- 以后再遇到它的语境、联想。WordSnap 只在这里追加，不会覆盖 -->

        \(entry.word)::\(meanings.first ?? entry.meaning)
        """
        return out
    }
}
