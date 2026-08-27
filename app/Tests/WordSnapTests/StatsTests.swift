import XCTest
@testable import WordSnap

final class StatsTests: XCTestCase {

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(_ offset: Int) -> String {
        fmt.string(from: Calendar.current.date(byAdding: .day, value: -offset, to: Date())!)
    }

    private func row(_ word: String, _ date: String) -> String {
        "| [[\(word)]] | /x/ | n. | 释义 | 例句 | Youdao | \(date) |\n"
    }

    func testCountsRowsAndStreakAcrossContiguousDays() {
        var content = "| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |\n|---|---|---|---|---|---|---|\n"
        content += row("today", day(0))
        content += row("yesterday1", day(1))
        content += row("yesterday2", day(1))   // 同日两行
        content += row("twoDaysAgo", day(2))
        content += row("lastWeek", day(5))     // 断档，不算连续

        let stats = WordService.stats(in: content, on: Date())
        XCTAssertEqual(stats.total, 5)
        XCTAssertEqual(stats.streakDays, 3, "今天/昨天/前天连续，5 天前断档")
    }

    func testNoSaveTodayMeansZeroStreak() {
        var content = "| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |\n|---|---|---|---|---|---|---|\n"
        content += row("old", day(1))
        let stats = WordService.stats(in: content, on: Date())
        XCTAssertEqual(stats.total, 1)
        XCTAssertEqual(stats.streakDays, 0)
    }

    func testEmptyTableIsZeroed() {
        let stats = WordService.stats(in: "| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |\n|---|---|---|---|---|---|---|\n")
        XCTAssertEqual(stats.total, 0)
        XCTAssertEqual(stats.streakDays, 0)
    }
}
