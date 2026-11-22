import XCTest
@testable import WordSnap

@MainActor
final class SearchModelTests: XCTestCase {
    private func entry(_ word: String) -> WordEntry {
        WordEntry(word: word, phonetic: "", partOfSpeech: "n.", meaning: "测试",
                  englishDef: "", example: "", source: "Youdao", date: "2026-11-21", star: nil)
    }

    /// Deliberately ignores cancellation, as an already-started transport may do.
    @MainActor private final class PendingLookup {
        var requests: [String: CheckedContinuation<WordEntry, Error>] = [:]
        var onStart: ((String) -> Void)?

        func lookup(_ word: String) async throws -> WordEntry {
            try await withCheckedThrowingContinuation { continuation in
                requests[word] = continuation
                onStart?(word)
            }
        }

        func complete(_ word: String, with result: Result<WordEntry, Error>) {
            requests.removeValue(forKey: word)!.resume(with: result)
        }
    }

    @MainActor private final class ManualScheduler {
        var work: [DispatchWorkItem] = []
        var hides = 0
        func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) { work.append(item) }
        func fire() { work.forEach { $0.perform() } }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wordsnap-model-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testOlderQueryCannotReplaceLatestResultOrPrefetchItsAudio() async throws {
        let pending = PendingLookup()
        let started = expectation(description: "Both requests started")
        started.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "Slow request started")
        var prefetched: [String] = []
        pending.onStart = { word in
            started.fulfill()
            if word == "slow" { firstStarted.fulfill() }
        }
        let model = SearchModel(lookupWord: pending.lookup, prefetchAudio: { prefetched.append($0) })
        model.searchText = "slow"
        let slow = Task { await model.lookup() }
        // Wait for the first request before starting the second; no timing sleeps.
        await fulfillment(of: [firstStarted], timeout: 2)
        model.searchText = "fast"
        let fast = Task { await model.lookup() }
        await fulfillment(of: [started], timeout: 2)

        pending.complete("fast", with: .success(entry("fast")))
        await fast.value
        pending.complete("slow", with: .success(entry("slow")))
        await slow.value

        XCTAssertEqual(model.searchText, "fast")
        XCTAssertEqual(model.phase, .loaded(entry("fast")))
        XCTAssertEqual(prefetched, ["fast"])
    }

    func testResetIgnoresLateFailureAndClearsSuggestions() async {
        let pending = PendingLookup()
        let started = expectation(description: "Request started")
        pending.onStart = { _ in started.fulfill() }
        let model = SearchModel(lookupWord: pending.lookup, prefetchAudio: { _ in })
        model.searchText = "typo"
        let task = Task { await model.lookup() }
        await fulfillment(of: [started], timeout: 2)
        model.suggestions = ["previous"]
        model.reset()
        pending.complete("typo", with: .failure(LookupError.notFound(["suggestion"])))
        await task.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.searchText, "")
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    func testResetIgnoresLateSuccessfulQuery() async {
        let pending = PendingLookup()
        let started = expectation(description: "Request started")
        pending.onStart = { _ in started.fulfill() }
        let model = SearchModel(lookupWord: pending.lookup, prefetchAudio: { _ in XCTFail("Stale audio") })
        model.searchText = "old"
        let task = Task { await model.lookup() }
        await fulfillment(of: [started], timeout: 2)
        model.reset()
        pending.complete("old", with: .success(entry("old")))
        await task.value
        XCTAssertEqual(model.phase, .idle)
    }

    func testNewQueryCancelsPreviousSaveTimer() async throws {
        let directory = try temporaryDirectory()
        let timer = ManualScheduler()
        let model = SearchModel(lookupWord: { self.entry($0) }, prefetchAudio: { _ in },
                                tablePath: { directory.appendingPathComponent("vocab.md").path },
                                schedule: timer.schedule, hidePanel: { timer.hides += 1 })
        model.phase = .loaded(entry("first"))
        model.save()
        XCTAssertEqual(timer.work.count, 1)
        model.searchText = "second"
        await model.lookup()
        timer.fire()

        XCTAssertEqual(model.phase, .loaded(entry("second")))
        XCTAssertEqual(timer.hides, 0)
        XCTAssertFalse(model.canUndoSave)
    }

    func testResetCancelsSaveTimerBeforeNewSession() throws {
        let directory = try temporaryDirectory()
        let timer = ManualScheduler()
        let model = SearchModel(prefetchAudio: { _ in },
                                tablePath: { directory.appendingPathComponent("vocab.md").path },
                                schedule: timer.schedule, hidePanel: { timer.hides += 1 })
        model.phase = .loaded(entry("first"))
        model.save()
        model.reset()
        model.searchText = "new session"
        timer.fire()
        XCTAssertEqual(model.searchText, "new session")
        XCTAssertEqual(timer.hides, 0)
    }

    func testSaveTimerStillHidesUnchangedSession() throws {
        let directory = try temporaryDirectory()
        let timer = ManualScheduler()
        let model = SearchModel(tablePath: { directory.appendingPathComponent("vocab.md").path },
                                schedule: timer.schedule, hidePanel: { timer.hides += 1 })
        model.phase = .loaded(entry("word"))
        model.save()
        timer.fire()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(timer.hides, 1)
        XCTAssertFalse(model.canUndoSave)
    }

    func testTypingCancelsSaveTimerBeforeSubmittingNextQuery() throws {
        let directory = try temporaryDirectory()
        let timer = ManualScheduler()
        let model = SearchModel(tablePath: { directory.appendingPathComponent("vocab.md").path },
                                schedule: timer.schedule, hidePanel: { timer.hides += 1 })
        model.phase = .loaded(entry("first"))
        model.save()
        model.searchText = "next word"
        timer.fire()
        XCTAssertEqual(model.searchText, "next word")
        XCTAssertEqual(timer.hides, 0)
    }

    func testNoteFailureIsVisibleAndRetryDoesNotDuplicateTableRow() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("vocab.md").path
        let blockedDirectory = directory.appendingPathComponent("Vocabulary")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let timer = ManualScheduler()
        let model = SearchModel(tablePath: { path }, schedule: timer.schedule)
        model.phase = .loaded(entry("word"))
        model.save()

        guard case .noteFailed = model.phase else { return XCTFail("Must expose partial save failure") }
        XCTAssertTrue(model.canUndoSave)
        XCTAssertTrue(timer.work.isEmpty, "An error must remain visible for retry")
        XCTAssertEqual(WordService.tableRows(in: try String(contentsOfFile: path, encoding: .utf8)).count, 1)

        try FileManager.default.removeItem(at: blockedDirectory)
        model.retryNoteSave()
        XCTAssertEqual(model.phase, .saved(total: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: NoteWriter.notePath(for: "word", tablePath: path)))
        XCTAssertEqual(WordService.tableRows(in: try String(contentsOfFile: path, encoding: .utf8)).count, 1)
        model.undoSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: NoteWriter.notePath(for: "word", tablePath: path)))
    }

    func testUndoUsesSaveDestinationAfterSettingsChange() throws {
        let directory = try temporaryDirectory()
        let a = directory.appendingPathComponent("A/vocab.md").path
        let b = directory.appendingPathComponent("B/vocab.md").path
        let word = entry("word")
        _ = try WordService.shared.save(word, tablePath: b)
        try NoteWriter.writeIfMissing(word, tablePath: b)
        let originalB = try Data(contentsOf: URL(fileURLWithPath: b))
        let originalNoteB = try Data(contentsOf: URL(fileURLWithPath: NoteWriter.notePath(for: "word", tablePath: b)))
        var destination = a
        let model = SearchModel(tablePath: { destination }, schedule: { _, _ in })
        model.phase = .loaded(word)
        model.save()
        destination = b
        model.undoSave()

        XCTAssertFalse(WordService.containsWord("word", in: try String(contentsOfFile: a, encoding: .utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: NoteWriter.notePath(for: "word", tablePath: a)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: b)), originalB)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: NoteWriter.notePath(for: "word", tablePath: b))), originalNoteB)
    }

    func testNoteRetryUsesOriginalDestinationAfterSettingsChange() throws {
        let directory = try temporaryDirectory()
        let a = directory.appendingPathComponent("A/vocab.md").path
        let b = directory.appendingPathComponent("B/vocab.md").path
        let blocked = URL(fileURLWithPath: NoteWriter.noteDirectory(tablePath: a))
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocking file".utf8).write(to: blocked)
        var destination = a
        let model = SearchModel(tablePath: { destination }, schedule: { _, _ in })
        model.phase = .loaded(entry("word"))
        model.save()
        guard case .noteFailed = model.phase else { return XCTFail("Expected a retryable failure") }
        destination = b
        try FileManager.default.removeItem(at: blocked)
        model.retryNoteSave()
        XCTAssertEqual(model.phase, .saved(total: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: NoteWriter.notePath(for: "word", tablePath: a)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: NoteWriter.noteDirectory(tablePath: b)))
    }

    func testUndoPreservesPreexistingNote() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("vocab.md").path
        let word = entry("word")
        try NoteWriter.writeIfMissing(word, tablePath: path)
        let notePath = NoteWriter.notePath(for: "word", tablePath: path)
        let original = try Data(contentsOf: URL(fileURLWithPath: notePath))
        let model = SearchModel(tablePath: { path }, schedule: { _, _ in })
        model.phase = .loaded(word)
        model.save()
        model.undoSave()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: notePath)), original)
    }

    func testFailedUndoRemainsRetryableAndDoesNotDeleteNote() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("vocab.md").path
        let model = SearchModel(tablePath: { path }, schedule: { _, _ in })
        model.phase = .loaded(entry("word"))
        model.save()
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let corrupt = Data([0xff, 0xfe, 0x00])
        try corrupt.write(to: URL(fileURLWithPath: path))
        model.undoSave()
        XCTAssertNotNil(model.undoError)
        XCTAssertTrue(model.canUndoSave)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: NoteWriter.notePath(for: "word", tablePath: path)))

        try original.write(to: URL(fileURLWithPath: path))
        model.undoSave()
        XCTAssertNil(model.undoError)
        XCTAssertFalse(model.canUndoSave)
    }

    func testNewQueryCancelsUndoTimer() async throws {
        let directory = try temporaryDirectory()
        let timer = ManualScheduler()
        let model = SearchModel(lookupWord: { self.entry($0) }, prefetchAudio: { _ in },
                                tablePath: { directory.appendingPathComponent("vocab.md").path },
                                schedule: timer.schedule, hidePanel: { timer.hides += 1 })
        model.phase = .loaded(entry("first"))
        model.save()
        model.undoSave()
        model.searchText = "second"
        await model.lookup()
        timer.fire()
        XCTAssertEqual(timer.hides, 0)
        XCTAssertEqual(model.phase, .loaded(entry("second")))
    }

    func testRetryOfPartialUndoDoesNotDeleteAnotherWritersNewRow() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("vocab.md").path
        let model = SearchModel(tablePath: { path }, schedule: { _, _ in })
        model.phase = .loaded(entry("word"))
        model.save()
        let noteURL = URL(fileURLWithPath: NoteWriter.notePath(for: "word", tablePath: path))
        let originalNote = try Data(contentsOf: noteURL)
        try FileManager.default.removeItem(at: noteURL)
        try FileManager.default.createDirectory(at: noteURL, withIntermediateDirectories: false)

        model.undoSave()
        XCTAssertNotNil(model.undoError)
        XCTAssertTrue(model.canUndoSave)
        XCTAssertFalse(WordService.containsWord("word", in: try String(contentsOfFile: path, encoding: .utf8)))

        // Another writer saves the same word after our table deletion succeeded.
        var anotherEntry = entry("word")
        anotherEntry.meaning = "Another writer's new record"
        _ = try WordService.shared.save(anotherEntry, tablePath: path)
        let newerTable = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.removeItem(at: noteURL)
        try originalNote.write(to: noteURL)
        model.undoSave()

        XCTAssertNil(model.undoError)
        XCTAssertFalse(model.canUndoSave)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), newerTable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    }

    func testSuccessfulNoteRetryClearsPreviousUndoError() throws {
        let directory = try temporaryDirectory()
        let tableURL = directory.appendingPathComponent("vocab.md")
        let blocked = directory.appendingPathComponent("Vocabulary")
        try Data("blocking file".utf8).write(to: blocked)
        let model = SearchModel(tablePath: { tableURL.path }, schedule: { _, _ in })
        model.phase = .loaded(entry("word"))
        model.save()
        guard case .noteFailed = model.phase else { return XCTFail("Expected note failure") }
        let original = try Data(contentsOf: tableURL)
        try Data([0xff, 0xfe, 0x00]).write(to: tableURL)
        model.undoSave()
        XCTAssertNotNil(model.undoError)

        try original.write(to: tableURL)
        try FileManager.default.removeItem(at: blocked)
        model.retryNoteSave()
        XCTAssertEqual(model.phase, .saved(total: 1))
        XCTAssertNil(model.undoError)
    }
}
