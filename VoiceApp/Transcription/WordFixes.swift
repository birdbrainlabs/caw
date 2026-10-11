import Foundation

/// One word fix: when the recognizer writes `from`, the text says `to`.
///
/// Stored in the user's own `word-fixes.json` (see `WordFixStore`), so each
/// person keeps their own list. Every entry is that person's explicit decision —
/// nothing is added by inference.
///
/// Matching, exactly as the fixes have always worked:
/// - `from` is case-insensitive. Alternatives are separated by `|`, and a phrase
///   is written with its spaces ("bird brain"). It is a regular expression, so
///   rare cases can use lookaheads — "mark(?='s)" fixes "Mark's" but not "marks".
/// - `wholeWord` (default true): never fires inside a longer word.
/// - `endings` (default `'s|s`): an ending kept after the fix, in lower case —
///   "Clawed's" becomes "Claude's".
/// - `capitalization`:
///   - `always` — a proper noun; capitalised wherever it falls.
///   - `matchHeard` — capitalised only when the heard word was, so a sentence
///     can still start with "Chat".
///   - `exact` — written exactly as `to`, even at the start of a sentence.
struct WordFix: Codable, Equatable, Sendable {
    enum Capitalization: String, Codable, Sendable {
        case always
        case matchHeard
        case exact
    }

    var from: String
    var to: String
    var capitalization: Capitalization
    var wholeWord: Bool
    var endings: String
    var note: String?

    static let defaultEndings = "'s|s"

    init(from: String, to: String, capitalization: Capitalization,
         wholeWord: Bool = true, endings: String = WordFix.defaultEndings, note: String? = nil) {
        self.from = from
        self.to = to
        self.capitalization = capitalization
        self.wholeWord = wholeWord
        self.endings = endings
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, capitalization, wholeWord, endings, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        capitalization = try container.decodeIfPresent(Capitalization.self, forKey: .capitalization) ?? .matchHeard
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
        endings = try container.decodeIfPresent(String.self, forKey: .endings) ?? WordFix.defaultEndings
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Written the way the file has always been written by hand: settings that
    /// are at their default are left out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(capitalization, forKey: .capitalization)
        if !wholeWord { try container.encode(wholeWord, forKey: .wholeWord) }
        if endings != WordFix.defaultEndings { try container.encode(endings, forKey: .endings) }
        try container.encodeIfPresent(note, forKey: .note)
    }

    /// The pattern this entry matches. Group 1 is the kept ending.
    var pattern: String {
        let core = "(?:\(from))(\(endings))?"
        return wholeWord ? "(?<![A-Za-z])\(core)(?![A-Za-z])" : core
    }
}

/// The whole `word-fixes.json` file.
struct WordFixFile: Codable, Equatable, Sendable {
    var about: String?
    var version: Int
    var fixes: [WordFix]

    static func decode(_ data: Data) throws -> WordFixFile {
        try JSONDecoder().decode(WordFixFile.self, from: data)
    }
}

/// A list of fixes, compiled once and applied in order.
final class CompiledWordFixes: @unchecked Sendable {
    // NSRegularExpression is immutable and documented as thread-safe.
    private let rules: [(fix: WordFix, regex: NSRegularExpression)]

    /// Entries whose `from`/`endings` could not be compiled. They are skipped,
    /// exactly as an uncompilable rule always was.
    let invalidEntries: [String]

    static let empty = CompiledWordFixes([])

    init(_ fixes: [WordFix]) {
        var rules: [(WordFix, NSRegularExpression)] = []
        var invalid: [String] = []
        for fix in fixes {
            // A row still being typed in Settings. An empty pattern would match
            // between every pair of letters, so it is left out rather than run.
            if fix.from.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let regex = try? NSRegularExpression(pattern: fix.pattern, options: [.caseInsensitive]) {
                rules.append((fix, regex))
            } else {
                invalid.append(fix.from)
            }
        }
        self.rules = rules
        self.invalidEntries = invalid
    }

    var count: Int { rules.count }

    func apply(to transcript: String) -> String {
        var result = transcript
        for rule in rules {
            let fix = rule.fix
            result = Self.replaceMatches(of: rule.regex, in: result) { match, source in
                let heard = source[Range(match.range, in: source)!]
                let ending = (Self.capture(1, from: match, in: source) ?? "").lowercased()
                let word: String
                switch fix.capitalization {
                case .always:
                    word = fix.to.prefix(1).uppercased() + fix.to.dropFirst()
                case .matchHeard:
                    word = heard.first?.isUppercase == true
                        ? fix.to.prefix(1).uppercased() + fix.to.dropFirst()
                        : fix.to
                case .exact:
                    word = fix.to
                }
                return word + ending
            }
        }
        return result
    }

    private static func replaceMatches(
        of regex: NSRegularExpression,
        in source: String,
        replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            output.replaceCharacters(in: match.range, with: replacement(match, source))
        }
        return output as String
    }

    private static func capture(_ index: Int, from match: NSTextCheckingResult, in source: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }
}
