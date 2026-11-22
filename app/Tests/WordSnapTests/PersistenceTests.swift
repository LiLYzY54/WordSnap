import XCTest
@testable import WordSnap

final class PersistenceTests: XCTestCase {
    private var tempDirectory: URL!
    private var tablePath: String { tempDirectory.appendingPathComponent("nested/vocab.md").path }

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordsnap-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDirectory)
    }

    func testUnreadableEncodingThrowsWithoutChangingExistingBytes() throws {
        let path = tempDirectory.appendingPathComponent("existing.md")
        let original = Data([0xFF, 0xFE, 0x00, 0x61, 0x00, 0x62])
        try original.write(to: path)

        XCTAssertThrowsError(try WordService.shared.save(entry("new"), tablePath: path.path))
        XCTAssertEqual(try Data(contentsOf: path), original,
                       "A failed read must never replace the existing vocabulary file")
    }

    func testCreatesMissingDirectoryAndAppendsWithoutLosingExistingRows() throws {
        let first = try WordService.shared.save(entry("first"), tablePath: tablePath)
        let afterFirst = try String(contentsOfFile: tablePath, encoding: .utf8)
        let second = try WordService.shared.save(entry("second"), tablePath: tablePath)
        let afterSecond = try String(contentsOfFile: tablePath, encoding: .utf8)

        XCTAssertTrue(first.saved)
        XCTAssertEqual(first.totalCount, 1)
        XCTAssertTrue(second.saved)
        XCTAssertEqual(second.totalCount, 2)
        XCTAssertTrue(afterSecond.hasPrefix(afterFirst))
        XCTAssertEqual(WordService.allEntries(in: afterSecond).map(\.word), ["first", "second"])
        XCTAssertEqual(afterSecond.components(separatedBy: "| 单词 |").count - 1, 1)
    }

    func testDuplicateDoesNotRewriteExistingFile() throws {
        _ = try WordService.shared.save(entry("word"), tablePath: tablePath)
        let original = try Data(contentsOf: URL(fileURLWithPath: tablePath))

        let outcome = try WordService.shared.save(entry("WORD"), tablePath: tablePath)

        XCTAssertFalse(outcome.saved)
        XCTAssertEqual(outcome.existingDate, "2026-11-21")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tablePath)), original)
    }

    func testDeleteRowOnlyRemovesMatchingDataRowFromSpecifiedTable() throws {
        _ = try WordService.shared.save(entry("wordy"), tablePath: tablePath)
        var original = try String(contentsOfFile: tablePath, encoding: .utf8)
        let aliasRow = "| [[word|alias]] | /w/ | n. | 词 | a\\|b | Youdao | 2026-11-21 |\n"
        original += aliasRow + "| word | a different two-column table |\n"
        try original.write(toFile: tablePath, atomically: true, encoding: .utf8)
        let otherPath = tempDirectory.appendingPathComponent("other.md").path
        try original.write(toFile: otherPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(try WordService.shared.deleteRow(word: "WORD", tablePath: tablePath))
        XCTAssertEqual(try String(contentsOfFile: tablePath, encoding: .utf8),
                       original.replacingOccurrences(of: aliasRow, with: ""))
        XCTAssertEqual(try String(contentsOfFile: otherPath, encoding: .utf8), original)
        XCTAssertFalse(try WordService.shared.deleteRow(word: "word", tablePath: tablePath))
    }

    func testDeleteReadFailureThrowsWithoutChangingExistingBytes() throws {
        let path = tempDirectory.appendingPathComponent("existing.md")
        let original = Data([0xFF, 0xFE, 0x00, 0x61])
        try original.write(to: path)

        XCTAssertThrowsError(try WordService.shared.deleteRow(word: "word", tablePath: path.path))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(try WordService.shared.deleteRow(word: "word", tablePath: tablePath))
    }

    private func entry(_ word: String) -> WordEntry {
        WordEntry(word: word, phonetic: "", partOfSpeech: "n.", meaning: "测试",
                  englishDef: "", example: "", source: "Youdao", date: "2026-11-21", star: nil)
    }
}
