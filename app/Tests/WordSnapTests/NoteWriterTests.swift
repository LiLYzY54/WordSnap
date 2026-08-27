import XCTest
@testable import WordSnap

final class NoteWriterTests: XCTestCase {

    private var tempDir: String!
    private var tablePath: String { tempDir + "/vocab.md" }

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "wsnotes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func entry(word: String = "serendipity",
                       meaning: String = "n. 意外发现美好事物的运气; 妙缘",
                       star: String? = "4") -> WordEntry {
        WordEntry(word: word, phonetic: "ˌserənˈdɪpəti", partOfSpeech: "n.",
                  meaning: meaning, englishDef: "The faculty of finding valuable things by chance.",
                  example: "It was pure serendipity.", source: "Youdao",
                  date: "2026-08-27", star: star)
    }

    func testTemplateRendersFrontmatterAndFlashcard() throws {
        XCTAssertTrue(NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        let note = try String(contentsOfFile: NoteWriter.notePath(for: "serendipity", tablePath: tablePath),
                              encoding: .utf8)
        XCTAssertTrue(note.contains("word: serendipity"))
        XCTAssertTrue(note.contains("phonetic: /ˌserənˈdɪpəti/"), "音标应补斜杠")
        XCTAssertTrue(note.contains("star: ★★★★☆"))
        XCTAssertTrue(note.contains("status: new"))
        XCTAssertTrue(note.contains("tags: [vocabulary, flashcards]"))
        XCTAssertTrue(note.contains("- n. 意外发现美好事物的运气"))
        XCTAssertTrue(note.contains("## 英文释义"))
        XCTAssertTrue(note.contains("- It was pure serendipity."))
        XCTAssertTrue(note.contains("serendipity::n. 意外发现美好事物的运气"),
                      "单行 flashcard 取首个释义")
        let marker = note.range(of: "## 我的痕迹")
        let flashcard = note.range(of: "serendipity::")
        XCTAssertNotNil(marker); XCTAssertNotNil(flashcard)
        XCTAssertTrue(marker!.upperBound < flashcard!.lowerBound, "痕迹段在 flashcard 之前")
    }

    func testWriteIfMissingNeverOverwrites() throws {
        XCTAssertTrue(NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        let path = NoteWriter.notePath(for: "serendipity", tablePath: tablePath)
        let original = try String(contentsOfFile: path, encoding: .utf8)
        let mutated = entry(meaning: "不同的释义")
        XCTAssertFalse(NoteWriter.writeIfMissing(mutated, tablePath: tablePath),
                       "已存在的笔记绝不覆盖")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testAppendEncounterInsertsUnderTraceSection() throws {
        XCTAssertTrue(NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        NoteWriter.appendEncounter(entry(), tablePath: tablePath)
        NoteWriter.appendEncounter(entry(), note: "又在论文里见到了", tablePath: tablePath)
        let note = try String(contentsOfFile: NoteWriter.notePath(for: "serendipity", tablePath: tablePath),
                              encoding: .utf8)
        XCTAssertTrue(note.contains("- 2026-08-27 在阅读中又遇到了它"))
        XCTAssertTrue(note.contains("- 2026-08-27 又在论文里见到了"))
        XCTAssertTrue(note.contains("serendipity::"), "追加不破坏 flashcard")
    }

    func testAppendEncounterBackfillsMissingNote() throws {
        NoteWriter.appendEncounter(entry(), tablePath: tablePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: NoteWriter.notePath(for: "serendipity", tablePath: tablePath)),
            "笔记缺失时先补建")
    }

    func testStarsConversion() {
        XCTAssertEqual(NoteWriter.stars("4"), "★★★★☆")
        XCTAssertEqual(NoteWriter.stars("5"), "★★★★★")
        XCTAssertEqual(NoteWriter.stars("0"), "")
        XCTAssertEqual(NoteWriter.stars(nil), "")
        XCTAssertEqual(NoteWriter.stars("abc"), "")
    }

    func testSanitizesFilenameHostileCharacters() {
        let path = NoteWriter.notePath(for: "a/b:c", tablePath: tablePath)
        XCTAssertFalse(path.contains("a/b:c"))
        XCTAssertTrue(path.hasSuffix("Vocabulary/a-b-c.md"))
    }
}
