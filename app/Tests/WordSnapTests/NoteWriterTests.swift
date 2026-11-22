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
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
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
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        let path = NoteWriter.notePath(for: "serendipity", tablePath: tablePath)
        let original = try String(contentsOfFile: path, encoding: .utf8)
        let mutated = entry(meaning: "不同的释义")
        XCTAssertFalse(try NoteWriter.writeIfMissing(mutated, tablePath: tablePath),
                       "已存在的笔记绝不覆盖")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testAppendEncounterInsertsUnderTraceSection() throws {
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        XCTAssertFalse(try NoteWriter.appendEncounter(entry(), tablePath: tablePath))
        XCTAssertFalse(try NoteWriter.appendEncounter(entry(), note: "又在论文里见到了", tablePath: tablePath))
        let note = try String(contentsOfFile: NoteWriter.notePath(for: "serendipity", tablePath: tablePath),
                              encoding: .utf8)
        XCTAssertTrue(note.contains("- 2026-08-27 在阅读中又遇到了它"))
        XCTAssertTrue(note.contains("- 2026-08-27 又在论文里见到了"))
        XCTAssertTrue(note.contains("serendipity::"), "追加不破坏 flashcard")
    }

    func testAppendEncounterBackfillsMissingNote() throws {
        XCTAssertTrue(try NoteWriter.appendEncounter(entry(), tablePath: tablePath))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: NoteWriter.notePath(for: "serendipity", tablePath: tablePath)),
            "笔记缺失时先补建")
    }

    func testCreationFailureThrowsAndCanBeRetried() throws {
        let directory = NoteWriter.noteDirectory(tablePath: tablePath)
        try "blocking file".write(toFile: directory, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        XCTAssertThrowsError(try NoteWriter.appendEncounter(entry(), tablePath: tablePath))
        XCTAssertEqual(try String(contentsOfFile: directory, encoding: .utf8), "blocking file")

        try FileManager.default.removeItem(atPath: directory)
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
    }

    func testEncounterReadFailurePreservesOriginalBytes() throws {
        try FileManager.default.createDirectory(atPath: NoteWriter.noteDirectory(tablePath: tablePath),
                                                withIntermediateDirectories: true)
        let path = NoteWriter.notePath(for: "serendipity", tablePath: tablePath)
        let original = Data([0xFF, 0xFE, 0x00, 0x61])
        try original.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try NoteWriter.appendEncounter(entry(), tablePath: tablePath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testMissingTraceHeadingPreservesUserNotesAndFinalFlashcard() throws {
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        let path = NoteWriter.notePath(for: "serendipity", tablePath: tablePath)
        let original = "# My own notes\n\nUser-authored context.\n\nserendipity::奇缘\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(try NoteWriter.appendEncounter(entry(), tablePath: tablePath))
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(updated.hasPrefix("# My own notes\n\nUser-authored context."))
        XCTAssertTrue(updated.contains("## 我的痕迹\n- 2026-08-27 在阅读中又遇到了它"))
        XCTAssertTrue(updated.hasSuffix("serendipity::奇缘\n"))
    }

    func testDeleteNoteUsesExplicitTablePathAndMissingNoteIsHarmless() throws {
        XCTAssertTrue(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        XCTAssertTrue(try NoteWriter.deleteNote(for: "serendipity", tablePath: tablePath))
        XCTAssertFalse(try NoteWriter.deleteNote(for: "serendipity", tablePath: tablePath))
    }

    func testDirectoryAtNotePathIsAnErrorAndIsNeverDeleted() throws {
        let path = NoteWriter.notePath(for: "serendipity", tablePath: tablePath)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let marker = path + "/keep.txt"
        try "keep".write(toFile: marker, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try NoteWriter.writeIfMissing(entry(), tablePath: tablePath))
        XCTAssertThrowsError(try NoteWriter.deleteNote(for: "serendipity", tablePath: tablePath))
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "keep")
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
