import Foundation
import OSLog

/// Counts the word swaps `WordFixMining` finds in captured dictations, and
/// turns a swap seen often enough into a suggested fix (Phase 2b).
///
/// `suggestion-candidates.json`, in this edition's own folder, keeps one entry
/// per "heard → should be" pair: how many dictations it was seen in, when it was
/// first and last seen, and up to three app names. No sentences. When a pair
/// reaches `suggestionThreshold` it is added to the Suggested Fixes list
/// (`WordFixSuggestionStore`) with its count, and the count keeps rising there.
/// Nothing is ever applied: only the user's Approve moves a pair into
/// word-fixes.json, and Reject hides it for good.
///
/// Pairs that an existing word fix already rewrites are not counted. Pairs
/// whose heard side is a very common word are still suggested, marked
/// "careful: common word".
///
/// The first launch of this build also mines the read-back log already on disk
/// (`backfillOnce`), so earlier dictations count. Personal only in practice:
/// the Beta read-back log holds no text, so there is nothing to mine there.
final class WordFixCandidateStore: @unchecked Sendable {
    static let shared = WordFixCandidateStore(
        fileURL: AppEdition.supportDirectory.appendingPathComponent(WordFixCandidateStore.fileName),
        suggestions: .shared, wordFixes: .shared)

    static let fileName = "suggestion-candidates.json"
    static let suggestionThreshold = 2

    let fileURL: URL
    private let suggestions: WordFixSuggestionStore
    private let wordFixes: WordFixStore
    private let lock = NSLock()
    private let queue = DispatchQueue(label: AppEdition.queueLabel("WordFixCandidates"), qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "WordFixes")

    init(fileURL: URL, suggestions: WordFixSuggestionStore, wordFixes: WordFixStore) {
        self.fileURL = fileURL
        self.suggestions = suggestions
        self.wordFixes = wordFixes
    }

    // MARK: - Called by ReadbackProbe and at launch

    /// One captured dictation, mined off the caller's thread.
    func mineInBackground(inserted: String, landed: String?, final: String, otherTextInBox: Bool, app: String) {
        let now = Date()
        queue.async { [self] in
            mine(inserted: inserted, landed: landed, final: final, otherTextInBox: otherTextInBox, app: app, at: now)
        }
    }

    /// Mines readback-probe.jsonl once, the first time this build runs, so the
    /// dictations captured before it count too. Only records from before
    /// `before` are read; later ones are mined live.
    func backfillOnceInBackground(probeLog: URL, before: Date = Date()) {
        queue.async { [self] in
            backfillOnce(probeLog: probeLog, before: before)
        }
    }

    // MARK: - Synchronous (tests call these directly)

    /// Mines one captured dictation. Returns the pairs that became or updated
    /// a suggestion.
    @discardableResult
    func mine(inserted: String, landed: String?, final: String, otherTextInBox: Bool, app: String,
              at date: Date = Date()) -> [WordFixMining.Pair] {
        let pairs = WordFixMining.pairs(inserted: inserted, landed: landed, final: final, otherTextInBox: otherTextInBox)
        guard !pairs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        let promoted = file.tally.add(pairs, app: app, at: date, existingFixes: wordFixes.current)
        do {
            try writeLocked(file)
        } catch {
            logger.error("Could not save suggestion-candidates.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
        publish(promoted, from: file.tally)
        return promoted
    }

    /// Returns the number of dictations mined, or nil if the backfill had
    /// already run.
    @discardableResult
    func backfillOnce(probeLog: URL, before: Date) -> Int? {
        lock.lock(); defer { lock.unlock() }
        var file = readLocked()
        guard file.backfilledAt == nil else { return nil }

        let text = (try? String(contentsOf: probeLog, encoding: .utf8)) ?? ""
        let records = ReadbackResults.parse(text)
        let parser = ISO8601DateFormatter()
        let existing = wordFixes.current
        var mined = 0
        var promoted: [WordFixMining.Pair] = []
        for record in records where record.finalCaptured && !record.secure {
            guard let inserted = record.insertedText, let final = record.finalText,
                  let date = parser.date(from: record.timestamp), date < before else { continue }
            mined += 1
            let pairs = WordFixMining.pairs(inserted: inserted, landed: nil, final: final,
                                            otherTextInBox: record.otherTextInBox)
            promoted += file.tally.add(pairs, app: record.appName, at: date, existingFixes: existing)
        }
        file.backfilledAt = ISO8601DateFormatter().string(from: Date())
        do {
            try writeLocked(file)
        } catch {
            logger.error("Could not save suggestion-candidates.json: \(error.localizedDescription, privacy: .public)")
            return mined
        }
        var seen = Set<String>()
        publish(promoted.filter { seen.insert($0.key).inserted }, from: file.tally)
        logger.notice("Mined \(mined, privacy: .public) earlier dictations for suggested fixes")
        return mined
    }

    /// The whole candidate file as it is now.
    func load() -> WordFixCandidateFile {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    // MARK: - Private

    /// Adds or updates the suggestions for pairs that reached the threshold.
    private func publish(_ promoted: [WordFixMining.Pair], from tally: WordFixCandidateTally) {
        for pair in promoted {
            guard let candidate = tally.candidates[pair.key] else { continue }
            do {
                try suggestions.upsertLearned(
                    heard: candidate.heard, shouldBe: candidate.shouldBe, count: candidate.count,
                    commonWord: WordFixMining.isCommonWord(candidate.heard))
            } catch {
                logger.error("Could not save a suggested fix: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func readLocked() -> WordFixCandidateFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(WordFixCandidateFile.self, from: data) else {
            return WordFixCandidateFile()
        }
        return file
    }

    private func writeLocked(_ file: WordFixCandidateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// `suggestion-candidates.json`.
struct WordFixCandidateFile: Codable, Equatable, Sendable {
    var about: String? = WordFixCandidateFile.defaultAbout
    var version = 1
    /// When the read-back log already on disk was mined (once).
    var backfilledAt: String?
    var tally = WordFixCandidateTally()

    static let defaultAbout = "Word swaps seen in your edits after dictating, counted. Seen twice or more, a swap is shown in Settings › Words & Learning › Suggested Fixes. Only word pairs are kept here, never sentences."
}

/// One counted pair.
struct WordFixCandidate: Codable, Equatable, Sendable {
    var heard: String
    var shouldBe: String
    var count: Int
    var firstSeen: String
    var lastSeen: String
    /// Up to three app names it was seen in.
    var apps: [String]
    /// `shouldBe`'s capitals come from mid-sentence, where they are the user's.
    var spellingFromMidSentence: Bool
}

/// The counting, apart from the file, so a dry run can use it too.
struct WordFixCandidateTally: Codable, Equatable, Sendable {
    /// By `WordFixMining.Pair.key`.
    var candidates: [String: WordFixCandidate] = [:]

    /// Counts one dictation's pairs (each pair once per dictation). Pairs an
    /// existing fix already rewrites are skipped. Returns the pairs now at or
    /// over the suggestion threshold.
    mutating func add(_ pairs: [WordFixMining.Pair], app: String, at date: Date,
                      existingFixes: CompiledWordFixes) -> [WordFixMining.Pair] {
        let stamp = ISO8601DateFormatter().string(from: date)
        var promoted: [WordFixMining.Pair] = []
        var seen = Set<String>()
        for pair in pairs where seen.insert(pair.key).inserted {
            if existingFixes.apply(to: pair.heard).lowercased() != pair.heard.lowercased() { continue }
            if var candidate = candidates[pair.key] {
                let isNewest = stamp >= candidate.lastSeen
                candidate.count += 1
                candidate.firstSeen = min(candidate.firstSeen, stamp)
                candidate.lastSeen = max(candidate.lastSeen, stamp)
                if !candidate.apps.contains(app), candidate.apps.count < 3 { candidate.apps.append(app) }
                // Mid-sentence spelling wins over sentence-start spelling.
                if !pair.atSentenceStart && (!candidate.spellingFromMidSentence || isNewest) {
                    candidate.shouldBe = pair.shouldBe
                    candidate.spellingFromMidSentence = true
                }
                candidates[pair.key] = candidate
            } else {
                candidates[pair.key] = WordFixCandidate(
                    heard: pair.heard, shouldBe: pair.shouldBe, count: 1, firstSeen: stamp, lastSeen: stamp,
                    apps: [app], spellingFromMidSentence: !pair.atSentenceStart)
            }
            if let count = candidates[pair.key]?.count, count >= WordFixCandidateStore.suggestionThreshold {
                promoted.append(pair)
            }
        }
        return promoted
    }

    /// Pairs at or over the threshold.
    var suggestable: [WordFixCandidate] {
        candidates.values.filter { $0.count >= WordFixCandidateStore.suggestionThreshold }
    }
}
