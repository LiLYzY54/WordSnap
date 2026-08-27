import XCTest
@testable import WordSnap

final class CompanionDataTests: XCTestCase {

    private static let table = """
    | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
    |------|------|------|------|------|------|------|
    | [[serendipity]] | /x/ | n. | 奇缘 | - | Youdao | 2026-08-01 |
    | [[word|alias]] | /x/ | n. | 词 | - | Youdao | 2026-08-02 |
    | [[ephemeral]] | /x/ | adj. | 短暂的 | - | Youdao | 2026-08-02 |

    不是表格行。
    """

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: iso)!
    }

    func testWordOfTheDayIsStableWithinDayAndRotates() {
        let allWords = ["serendipity", "word", "ephemeral"]
        let d1 = WordService.wordOfTheDay(in: Self.table, on: date("2026-08-01"))
        let d1again = WordService.wordOfTheDay(in: Self.table, on: date("2026-08-01"))
        let d2 = WordService.wordOfTheDay(in: Self.table, on: date("2026-08-02"))
        XCTAssertNotNil(d1)
        XCTAssertEqual(d1, d1again, "同一天必须稳定")
        XCTAssertTrue(allWords.contains(d1?.word ?? ""))
        XCTAssertNotEqual(d1, d2, "相邻两天应轮换")
        XCTAssertTrue(allWords.contains(d2?.word ?? ""))
    }

    func testWordOfTheDayOnEmptyTableIsNil() {
        XCTAssertNil(WordService.wordOfTheDay(in: "空空如也", on: Date()))
    }

    func testDateCountsForHeatmap() {
        let counts = WordService.dateCounts(in: Self.table)
        XCTAssertEqual(counts["2026-08-01"], 1)
        XCTAssertEqual(counts["2026-08-02"], 2)
        XCTAssertEqual(counts.count, 2)
    }
}
