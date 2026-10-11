import Foundation
import OSLog

/// A word fix Caw thinks the user might want, waiting for a yes or no.
///
/// Nothing is ever applied because it was suggested — only approving it adds it
/// to `word-fixes.json`. Rejecting it keeps it in the file marked `rejected`, so
/// the same suggestion is never shown again.
///
/// Filled by `WordFixCandidateStore` (Phase 2b): a word swap seen in the
/// user's own edits at least twice arrives here with its count.
struct WordFixSuggestion: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case rejected
    }

    var id: String
    /// What the recognizer wrote.
    var heard: String
    /// What the user changed it to.
    var shouldBe: String
    /// How many times this change was seen, if known.
    var count: Int?
    /// One sentence it came from, if known.
    var example: String?
    var status: Status
    var created: String?
    /// The heard side is a very common word; a fix would also change it in
    /// ordinary sentences. Shown as "careful: common word".
    var commonWord: Bool?

    init(id: String = UUID().uuidString, heard: String, shouldBe: String, count: Int? = nil,
         example: String? = nil, status: Status = .pending, created: String? = nil, commonWord: Bool? = nil) {
        self.id = id
        self.heard = heard
        self.shouldBe = shouldBe
        self.count = count
        self.example = example
        self.status = status
        self.created = created
        self.commonWord = commonWord
    }

    /// Two suggestions are the same change when they fix the same heard words
    /// (ignoring case) to exactly the same result.
    var key: String { heard.lowercased() + "\u{1F}" + shouldBe }

    /// The same change ignoring case on both sides — how learned suggestions
    /// are matched, so a rejected pair stays hidden whatever its capitals.
    var pairKey: String { heard.lowercased() + "\u{1F}" + shouldBe.lowercased() }
}

struct WordFixSuggestionFile: Codable, Equatable, Sendable {
    var about: String?
    var version: Int
    var suggestions: [WordFixSuggestion]
}

/// Keeps `word-fix-suggestions.json` next to `word-fixes.json`.
final class WordFixSuggestionStore: @unchecked Sendable {
    static let shared = WordFixSuggestionStore(
        fileURL: AppEdition.supportDirectory.appendingPathComponent(WordFixSuggestionStore.fileName),
        wordFixes: .shared)

    static let fileName = "word-fix-suggestions.json"

    enum SuggestionError: LocalizedError {
        case notFound
        var errorDescription: String? { "That suggestion is no longer there." }
    }

    let fileURL: URL
    private let wordFixes: WordFixStore
    private let lock = NSLock()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "WordFixes")

    init(fileURL: URL, wordFixes: WordFixStore) {
        self.fileURL = fileURL
        self.wordFixes = wordFixes
    }

    /// Suggestions still waiting for an answer, oldest first.
    var pending: [WordFixSuggestion] {
        lock.lock(); defer { lock.unlock() }
        return readLocked().suggestions.filter { $0.status == .pending }
    }

    /// Adds a suggestion unless the same change is already waiting, was
    /// rejected before, or is already a word fix. Returns whether it was added.
    @discardableResult
    func add(_ suggestion: WordFixSuggestion) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        guard !file.suggestions.contains(where: { $0.key == suggestion.key }) else { return false }
        let existing = wordFixes.loadFile()?.fixes ?? []
        let asFix = Self.fix(from: suggestion)
        guard !existing.contains(where: { $0.from.lowercased() == asFix.from.lowercased() && $0.to == asFix.to }) else {
            return false
        }
        var added = suggestion
        added.status = .pending
        file.suggestions.append(added)
        try writeLocked(file)
        return true
    }

    /// A pair learned from the user's edits (`WordFixCandidateStore`) reached
    /// the threshold, or was seen again. Adds it, or updates the count (and
    /// spelling) of the one already waiting. Never brings back a rejected
    /// pair, and never suggests what is already a word fix. Returns whether
    /// the list changed.
    @discardableResult
    func upsertLearned(heard: String, shouldBe: String, count: Int, commonWord: Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        let incoming = WordFixSuggestion(heard: heard, shouldBe: shouldBe, count: count, commonWord: commonWord)
        if let index = file.suggestions.firstIndex(where: { $0.pairKey == incoming.pairKey }) {
            guard file.suggestions[index].status == .pending else { return false }
            var updated = file.suggestions[index]
            updated.count = count
            updated.shouldBe = shouldBe
            updated.commonWord = commonWord
            guard updated != file.suggestions[index] else { return false }
            file.suggestions[index] = updated
            try writeLocked(file)
            return true
        }
        let existing = wordFixes.loadFile()?.fixes ?? []
        let asFix = Self.fix(from: incoming)
        guard !existing.contains(where: { $0.from.lowercased() == asFix.from.lowercased() && $0.to.lowercased() == asFix.to.lowercased() }) else {
            return false
        }
        var added = incoming
        added.created = ISO8601DateFormatter().string(from: Date())
        file.suggestions.append(added)
        try writeLocked(file)
        logger.notice("Suggested a word fix learned from edits")
        return true
    }

    /// Adds the suggestion to the end of `word-fixes.json` (so it applies from
    /// the next dictation) and takes it off the list. Returns the new fix.
    @discardableResult
    func approve(id: String) throws -> WordFix {
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        guard let index = file.suggestions.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
            throw SuggestionError.notFound
        }
        let fix = Self.fix(from: file.suggestions[index])
        var fixes = wordFixes.loadFile()?.fixes ?? []
        fixes.append(fix)
        try wordFixes.save(fixes)
        file.suggestions.remove(at: index)
        try writeLocked(file)
        logger.notice("Approved a suggested word fix")
        return fix
    }

    /// Hides the suggestion for good: it stays in the file as `rejected`, so
    /// the same change is never suggested again.
    func reject(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        guard let index = file.suggestions.firstIndex(where: { $0.id == id }) else {
            throw SuggestionError.notFound
        }
        file.suggestions[index].status = .rejected
        try writeLocked(file)
    }

    /// The word fix an approved suggestion becomes: the heard words matched
    /// literally (not as a pattern), whole words only, and capitalised always
    /// when the user wrote a capital — a name — otherwise only when heard with one.
    static func fix(from suggestion: WordFixSuggestion) -> WordFix {
        let heard = suggestion.heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let to = suggestion.shouldBe.trimmingCharacters(in: .whitespacesAndNewlines)
        let isName = to.first?.isUppercase == true
        return WordFix(
            from: NSRegularExpression.escapedPattern(for: heard),
            to: to,
            capitalization: isName ? .always : .matchHeard,
            note: "Approved from suggestions" + (suggestion.count.map { ", seen \($0)x" } ?? "")
        )
    }

    // MARK: - Private

    private func readLocked() -> WordFixSuggestionFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(WordFixSuggestionFile.self, from: data) else {
            return WordFixSuggestionFile(about: Self.about, version: 1, suggestions: [])
        }
        return file
    }

    private func writeLocked(_ file: WordFixSuggestionFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let about = "Suggested word fixes, waiting for approval in Settings › Words & Learning. Approved ones move to word-fixes.json; rejected ones stay here so they are never suggested again."
}
