import AppKit
import SwiftUI

enum LookupPhase: Equatable {
    case idle
    case loading
    case loaded(WordEntry)
    case failed(String)
    case saved(total: Int)
    case reunion(entry: WordEntry, previousDate: String)
    /// The table is safe, but the companion note needs another attempt.
    case noteFailed(String)
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var searchText = "" {
        didSet {
            if searchText != oldValue { cancelAutoHide() }
        }
    }
    @Published var phase: LookupPhase = .idle
    @Published var selectAllToken = 0
    @Published var suggestions: [String] = []
    @Published private(set) var undoError: String?

    private let lookupWord: @MainActor (String) async throws -> WordEntry
    private let prefetchAudio: @MainActor (String) -> Void
    private let tablePath: @MainActor () -> String
    private let schedule: @MainActor (TimeInterval, DispatchWorkItem) -> Void
    private let hidePanel: @MainActor () -> Void
    private var lastPrefilledWord: String?
    private var lookupTask: Task<WordEntry, Error>?
    private var lookupID = UUID()
    private var hideWorkItem: DispatchWorkItem?
    private var hideID = UUID()

    private struct SavedRecord {
        let entry: WordEntry
        let tablePath: String
        var noteCreated = false
        var tableRowRemoved = false
    }

    private struct PendingNote {
        let entry: WordEntry
        let tablePath: String
        let outcome: SaveOutcome
    }

    private var savedRecord: SavedRecord?
    private var pendingNote: PendingNote?
    var canUndoSave: Bool { savedRecord != nil }

    init(
        lookupWord: @escaping @MainActor (String) async throws -> WordEntry = { try await WordService.shared.lookup($0) },
        prefetchAudio: @escaping @MainActor (String) -> Void = { Pronouncer.shared.prefetch($0) },
        tablePath: @escaping @MainActor () -> String = { WordService.obsidianFile },
        schedule: @escaping @MainActor (TimeInterval, DispatchWorkItem) -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
        },
        hidePanel: @escaping @MainActor () -> Void = {
            NotificationCenter.default.post(name: .wordSnapHidePanel, object: nil)
        }
    ) {
        self.lookupWord = lookupWord
        self.prefetchAudio = prefetchAudio
        self.tablePath = tablePath
        self.schedule = schedule
        self.hidePanel = hidePanel
    }

    deinit {
        lookupTask?.cancel()
        hideWorkItem?.cancel()
    }

    func prefillFromClipboard() {
        guard searchText.isEmpty,
              let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let word = Self.clipboardWord(raw), word != lastPrefilledWord else { return }
        lastPrefilledWord = word
        searchText = word
        selectAllToken += 1
    }

    private static func clipboardWord(_ text: String) -> String? {
        guard text.count <= 40,
              text.range(of: #"^[A-Za-z][A-Za-z\-']*$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    func lookup() async {
        let word = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { reset(); return }
        invalidateLookup()
        clearSaveState()
        let requestID = lookupID
        phase = .loading
        suggestions = []

        let operation = lookupWord
        let task = Task { try await operation(word) }
        lookupTask = task
        do {
            let entry = try await task.value
            // Cancellation is advisory; a transport can still return a late result.
            guard lookupID == requestID else { return }
            lookupTask = nil
            prefetchAudio(entry.word)
            phase = .loaded(entry)
        } catch {
            guard lookupID == requestID else { return }
            lookupTask = nil
            if error is CancellationError {
                phase = .idle
            } else {
                if case LookupError.notFound(let candidates) = error { suggestions = candidates }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func lookupReplacement(_ word: String) {
        searchText = word
        Task { await lookup() }
    }

    func save() {
        guard case .loaded(let entry) = phase else { return }
        clearSaveState()
        let path = tablePath()
        do {
            let outcome = try WordService.shared.save(entry, tablePath: path)
            if outcome.saved { savedRecord = SavedRecord(entry: entry, tablePath: path) }
            pendingNote = PendingNote(entry: entry, tablePath: path, outcome: outcome)
            retryNoteSave()
        } catch {
            phase = .failed("保存失败：\(error.localizedDescription)")
        }
    }

    /// Retry only the failed note write; the table must not be appended twice.
    func retryNoteSave() {
        guard let pending = pendingNote else { return }
        undoError = nil
        do {
            if pending.outcome.saved {
                let created = try NoteWriter.writeIfMissing(pending.entry, tablePath: pending.tablePath)
                savedRecord?.noteCreated = created
                phase = .saved(total: pending.outcome.totalCount)
            } else {
                try NoteWriter.appendEncounter(pending.entry, tablePath: pending.tablePath)
                phase = .reunion(entry: pending.entry, previousDate: pending.outcome.existingDate ?? "")
            }
            pendingNote = nil
            scheduleAutoHide(seconds: 4)
        } catch {
            phase = .noteFailed("词表已保存，但词笔记写入失败：\(error.localizedDescription)")
        }
    }

    func undoSave() {
        guard var record = savedRecord else { return }
        cancelAutoHide()
        undoError = nil
        do {
            // Both operations use the original destination, even if settings changed.
            // A retry must not delete a new row added after the first deletion.
            if !record.tableRowRemoved {
                try WordService.shared.deleteRow(word: record.entry.word, tablePath: record.tablePath)
                record.tableRowRemoved = true
                savedRecord = record
            }
            if record.noteCreated {
                try NoteWriter.deleteNote(for: record.entry.word, tablePath: record.tablePath)
            }
            reset()
            scheduleAutoHide(seconds: 0.8)
        } catch {
            // Keep the receipt so a failed deletion can be retried.
            undoError = "撤销失败：\(error.localizedDescription)"
        }
    }

    private func invalidateLookup() {
        lookupID = UUID()
        lookupTask?.cancel()
        lookupTask = nil
    }

    private func cancelAutoHide() {
        hideID = UUID()
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func clearSaveState() {
        cancelAutoHide()
        savedRecord = nil
        pendingNote = nil
        undoError = nil
    }

    private func scheduleAutoHide(seconds: TimeInterval) {
        cancelAutoHide()
        let timerID = hideID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hideID == timerID else { return }
            self.reset()
            self.hidePanel()
        }
        hideWorkItem = work
        schedule(seconds, work)
    }

    func reset() {
        invalidateLookup()
        clearSaveState()
        searchText = ""
        suggestions = []
        phase = .idle
    }
}

extension Notification.Name {
    static let wordSnapHidePanel = Notification.Name("wordSnapHidePanel")
}
