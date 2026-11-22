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

    private static func noteExists(at path: String) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "词笔记路径被文件夹占用：\(path)",
            ])
        }
        return true
    }

    /// 不存在则按模板创建。返回 true = 本次新建。
    @discardableResult
    static func writeIfMissing(_ entry: WordEntry, tablePath: String = WordService.obsidianFile) throws -> Bool {
        let path = notePath(for: entry.word, tablePath: tablePath)
        guard try !noteExists(at: path) else { return false }
        try FileManager.default.createDirectory(
            atPath: noteDirectory(tablePath: tablePath), withIntermediateDirectories: true)
        try template(for: entry).write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    /// 「我的痕迹」下追加一行重逢记录；返回 true 表示笔记缺失并在本次补建。
    @discardableResult
    static func appendEncounter(_ entry: WordEntry,
                                note: String = "在阅读中又遇到了它",
                                tablePath: String = WordService.obsidianFile) throws -> Bool {
        let path = notePath(for: entry.word, tablePath: tablePath)
        if try writeIfMissing(entry, tablePath: tablePath) { return true }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let encounter = "- \(entry.date) \(note)"

        var out = raw
        if let marker = raw.range(of: #"(?m)^## 我的痕迹[ \t]*\r?$"#, options: .regularExpression) {
            // Insert after the heading without replacing any user-authored text.
            out.insert(contentsOf: "\n\(encounter)", at: marker.upperBound)
        } else {
            let section = "## 我的痕迹\n\(encounter)\n\n"
            let cardPattern = "(?m)^" + NSRegularExpression.escapedPattern(for: entry.word) + "::"
            if let card = raw.range(of: cardPattern, options: .regularExpression) {
                out.insert(contentsOf: "\n" + section, at: card.lowerBound)
            } else {
                out += (raw.hasSuffix("\n") ? "\n" : "\n\n") + section
            }
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        return false
    }

    /// 撤销窗口专用：删除本次保存新建的笔记（只对新建标记调用）。
    @discardableResult
    static func deleteNote(for word: String, tablePath: String = WordService.obsidianFile) throws -> Bool {
        let path = notePath(for: word, tablePath: tablePath)
        guard try noteExists(at: path) else { return false }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
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
