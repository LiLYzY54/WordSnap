import XCTest
@testable import WordSnap

final class TableRowTests: XCTestCase {

    // MARK: - containsWord（去重）

    private static let existingTable = """
    | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
    |------|------|------|------|------|------|------|
    | [[serendipity]] | /ˌserənˈdipəti/ | n. | 奇缘 | lucky | Youdao | 2026-08-01 |
    | [[serendipity|别名]] | /ˌserənˈdipəti/ | n. | 旧格式遗留的别名气泡 | lucky | Youdao | 2026-08-01 |
    | [[word]] | /wɜːd/ | n. | 词 | a word | Youdao | 2026-08-02 |
    | [[ephemeral]] | /ɪˈfemərəl/ | adj. | 短暂的 | brief | Youdao | 2026-08-03 |

    普通段落文字，不该被当成行匹配。
    """

    func testFindsPlainAndLinkedForms() {
        XCTAssertTrue(WordService.containsWord("serendipity", in: Self.existingTable))
        XCTAssertTrue(WordService.containsWord("word", in: Self.existingTable))
        XCTAssertTrue(WordService.containsWord("ephemeral", in: Self.existingTable))
    }

    func testDedupeIsCaseInsensitive() {
        // 与 migrate_vocab.swift 的口径一致：大小写不敏感
        XCTAssertTrue(WordService.containsWord("WORD", in: Self.existingTable))
        XCTAssertTrue(WordService.containsWord("Ephemeral", in: Self.existingTable))
    }

    func testUnknownWordIsNotPresent() {
        XCTAssertFalse(WordService.containsWord("serenity", in: Self.existingTable))
        XCTAssertFalse(WordService.containsWord("", in: Self.existingTable))
    }

    // MARK: - markdownRow（写表格式）

    func testRowWrapsPhoneticInSlashes() {
        let entry = makeEntry(phonetic: "fæt")
        let row = WordService.markdownRow(for: entry)
        XCTAssertTrue(row.contains("/fæt/"), "音标应自动补斜杠: \(row)")
        XCTAssertTrue(row.contains("[[fat]]"), "单词列应是 Obsidian 双链")
        XCTAssertTrue(row.hasSuffix("|\n"))
        XCTAssertEqual(row.components(separatedBy: "|").count, 9,
                       "裸竖线会让 GFM 把一行拆成多列：7 列应为 9 段")
    }

    func testRowDoesNotDoubleWrapSlashedPhonetic() {
        let row = WordService.markdownRow(for: makeEntry(phonetic: "/fæt/"))
        XCTAssertTrue(row.contains("/fæt/"))
        XCTAssertFalse(row.contains("//fæt//"))
    }

    func testRowEscapesPipesAndNewlines() {
        let entry = makeEntry(meaning: "a|b\nc", example: "line1\nline2")
        let row = WordService.markdownRow(for: entry)
        XCTAssertTrue(row.contains(#"a\|b"#), "竖线应转义以免破坏表格")
        XCTAssertTrue(row.contains("line1 line2"), "例句换行应替换为空格")
        XCTAssertEqual(row.split(separator: "\n").count, 1, "单条记录必须占一行")
    }

    private func makeEntry(word: String = "fat",
                           phonetic: String = "fæt",
                           meaning: String = "胖",
                           example: String = "") -> WordEntry {
        WordEntry(word: word, phonetic: phonetic, partOfSpeech: "adj.",
                  meaning: meaning, englishDef: "", example: example,
                  source: "Youdao", date: "2026-08-27")
    }
}
