import Foundation

// The read-back test's bookkeeping, with no Accessibility and no files in it,
// so it can be tested with made-up data. `ReadbackProbe` does the reading and
// feeds what it sees into a `ReadbackTracker`; the tracker decides what the
// watch learned. See HANDOFF.md, "Phase 2a".

/// One line of `readback-probe.jsonl`: what one dictation's read-back found.
struct ReadbackRecord: Codable, Equatable, Sendable {
    var timestamp: String
    var bundleID: String
    var appName: String
    var role: String?
    var subrole: String?
    /// The text box's value could be read at least once.
    var readable: Bool
    /// Some read contained the inserted text (whitespace differences allowed).
    var containsInserted: Bool
    /// The last value seen is plausibly what was sent or left: the dictation
    /// was seen in the box, and the watch ended because the box emptied, focus
    /// left it, or the box itself went away.
    var finalCaptured: Bool
    /// The box went from having text to empty — usually the message was sent.
    var clearedBySend: Bool
    /// Only when `finalCaptured`: the final text differs from what was inserted.
    var edited: Bool
    /// Only when `finalCaptured`: characters changed between inserted and final.
    var editDistance: Int?
    /// A password field. Nothing was read.
    var secure: Bool
    /// The app accepted `AXManualAccessibility` (Electron and some Chromium apps).
    var manualAccessibilityUsed: Bool
    var error: String?

    /// Why the watch stopped: cleared, focusLeft, boxGone, newDictation,
    /// timeout, unreadable, secure, notATextBox.
    var endReason: String
    /// The box reported a selection or character count but not its text.
    var rangeOnly: Bool
    /// The box already held other text when the dictation landed, so `edited`
    /// is true even if the dictation itself was never touched.
    var otherTextInBox: Bool
    var insertedLength: Int
    var finalLength: Int?

    /// Why the app counts as Electron/Chromium (`ChromiumAppDetection`), if it does.
    var chromiumMarker: String? = nil
    /// What the app answered to `AXManualAccessibility` ("success",
    /// "attributeUnsupported", …); nil when it was not asked this run.
    var manualAccessibilityResult: String? = nil
    /// Focus lookups made after the paste (retried for about a second).
    var focusAttempts: Int? = nil

    /// Personal edition only — the same kind of data as corpus.jsonl.
    var insertedText: String?
    var finalText: String?
}

/// What the probe saw on one poll.
enum ReadbackObservation: Equatable, Sendable {
    /// The box's value, as text.
    case value(String)
    /// The value could not be read. `rangeAvailable` says whether the box
    /// still answered with a selection or character count.
    case valueUnavailable(rangeAvailable: Bool, error: String)
    /// Focus moved to a different element.
    case focusLeft
    /// A new dictation started, which supersedes this watch.
    case newDictation
    /// The 90-second window ran out.
    case timedOut
}

enum ReadbackEndReason: String, Sendable {
    case cleared, focusLeft, boxGone, newDictation, timeout, unreadable
}

/// Follows one text box after one dictation landed in it.
struct ReadbackTracker: Sendable {
    let inserted: String
    private(set) var readable = false
    private(set) var containsInserted = false
    private(set) var rangeOnly = false
    private(set) var lastNonEmpty: String?
    /// The first value that contained the dictation — the box as it landed.
    private(set) var landed: String?
    private(set) var endReason: ReadbackEndReason?
    private(set) var error: String?

    private let normalizedInserted: String

    init(inserted: String) {
        self.inserted = inserted
        self.normalizedInserted = ReadbackText.normalize(inserted)
    }

    var isFinished: Bool { endReason != nil }

    /// Feeds one poll. Returns true while the watch should keep going.
    @discardableResult
    mutating func observe(_ observation: ReadbackObservation) -> Bool {
        guard endReason == nil else { return false }
        switch observation {
        case .value(let value):
            readable = true
            let normalized = ReadbackText.normalize(value)
            if normalized.isEmpty {
                // Empty before anything appeared is the paste not having landed
                // yet; empty after text was there is the box being cleared.
                if lastNonEmpty != nil { endReason = .cleared }
            } else {
                lastNonEmpty = value
                if !normalizedInserted.isEmpty, normalized.contains(normalizedInserted) {
                    containsInserted = true
                    if landed == nil { landed = value }
                }
            }
        case .valueUnavailable(let rangeAvailable, let message):
            if readable {
                // It answered before, so the box itself went away — Electron
                // apps can rebuild their input when a message is sent.
                endReason = .boxGone
            } else {
                rangeOnly = rangeOnly || rangeAvailable
                error = message
                endReason = .unreadable
            }
        case .focusLeft:
            endReason = .focusLeft
        case .newDictation:
            endReason = .newDictation
        case .timedOut:
            endReason = .timeout
        }
        return endReason == nil
    }

    var finalCaptured: Bool {
        guard containsInserted, lastNonEmpty != nil, let endReason else { return false }
        return endReason == .cleared || endReason == .focusLeft || endReason == .boxGone
    }

    var clearedBySend: Bool { endReason == .cleared }

    var otherTextInBox: Bool {
        guard let landed else { return false }
        return ReadbackText.normalize(landed) != normalizedInserted
    }

    var edited: Bool {
        guard finalCaptured, let lastNonEmpty else { return false }
        return ReadbackText.normalize(lastNonEmpty) != normalizedInserted
    }

    var editDistance: Int? {
        guard finalCaptured, let lastNonEmpty else { return nil }
        return ReadbackText.editDistance(normalizedInserted, ReadbackText.normalize(lastNonEmpty))
    }

    /// The record for this watch, without the timestamp/app fields and without text.
    func record(timestamp: String, bundleID: String, appName: String, role: String?, subrole: String?,
                manualAccessibilityUsed: Bool) -> ReadbackRecord {
        ReadbackRecord(
            timestamp: timestamp, bundleID: bundleID, appName: appName, role: role, subrole: subrole,
            readable: readable, containsInserted: containsInserted, finalCaptured: finalCaptured,
            clearedBySend: clearedBySend, edited: edited, editDistance: editDistance, secure: false,
            manualAccessibilityUsed: manualAccessibilityUsed, error: error,
            endReason: (endReason ?? .timeout).rawValue, rangeOnly: rangeOnly, otherTextInBox: otherTextInBox,
            insertedLength: inserted.count, finalLength: lastNonEmpty?.count,
            insertedText: nil, finalText: nil
        )
    }
}

enum ReadbackText {
    /// Whitespace-insensitive form: runs of spaces, tabs, newlines, non-breaking
    /// and zero-width spaces become one space, and the ends are trimmed.
    static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "\u{00A0}" || scalar == "\u{200B}" || scalar == "\u{FEFF}"
            if isSpace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Character-level Levenshtein distance. Nil for texts too long to compare
    /// cheaply (a box holding a whole document, not a message).
    static func editDistance(_ a: String, _ b: String, limit: Int = 16_000_000) -> Int? {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        guard x.count * y.count <= limit else { return nil }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

/// One row of the "Read-back results" table.
struct ReadbackAppSummary: Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let dictations: Int
    let readable: Int
    let finalCaptured: Int
    let edited: Int
    let secure: Int

    static func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "—" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    var readablePercent: String { Self.percent(readable, of: dictations) }
    var capturedPercent: String { Self.percent(finalCaptured, of: dictations) }
    /// Edits can only be known for dictations whose final text was captured.
    var editedPercent: String { Self.percent(edited, of: finalCaptured) }
}

enum ReadbackResults {
    /// Parses readback-probe.jsonl, skipping lines that do not decode.
    static func parse(_ jsonl: String) -> [ReadbackRecord] {
        let decoder = JSONDecoder()
        return jsonl.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(ReadbackRecord.self, from: Data(line.utf8))
        }
    }

    /// Per-app totals, most-used app first.
    static func summarize(_ records: [ReadbackRecord]) -> [ReadbackAppSummary] {
        var byApp: [String: [ReadbackRecord]] = [:]
        for record in records { byApp[record.bundleID, default: []].append(record) }
        return byApp.map { bundleID, rows in
            ReadbackAppSummary(
                bundleID: bundleID,
                appName: rows.last?.appName ?? bundleID,
                dictations: rows.count,
                readable: rows.filter(\.readable).count,
                finalCaptured: rows.filter(\.finalCaptured).count,
                edited: rows.filter(\.edited).count,
                secure: rows.filter(\.secure).count
            )
        }
        .sorted { $0.dictations != $1.dictations ? $0.dictations > $1.dictations : $0.appName < $1.appName }
    }
}
