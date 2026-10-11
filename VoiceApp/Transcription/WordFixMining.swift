import Foundation

/// Finds likely mishearings in what the user changed after a dictation landed
/// (Phase 2b). Pure logic — no files, no Accessibility — so it can be tested
/// with made-up text. `WordFixCandidateStore` counts what this finds.
///
/// The read-back test hands over three texts: what was pasted, the box as the
/// paste landed in it (when known), and the box's last value before it was sent
/// or left. Most edits are not corrections: people type more around the
/// dictation, or the box already held other text. So only one shape counts:
///
/// - a SMALL substitution inside the dictation: 1–3 words replaced by 1–3
///   words, with words kept on both sides of it (or equal word counts where
///   the change touches the start or end of the box);
/// - that is not only punctuation or capitalisation (both are ignored when
///   comparing words, so such changes never show up as differences);
/// - in a dictation that was not rewritten (at most 3 words, or half of it,
///   changed; at most 3 such swaps);
/// - where the two sides are spelled alike, as a mishearing would be
///   (letters differing in at most two thirds of the longer side).
///
/// Pure insertions, appends and deletions are ignored, as is anything in the
/// text that was already in the box.
enum WordFixMining {
    /// One "heard → should be" change found in one dictation.
    struct Pair: Equatable, Hashable, Sendable {
        /// The dictated words, lower case, edge punctuation removed.
        let heard: String
        /// What the user wrote instead, as they wrote it (edge punctuation
        /// removed). At the start of a sentence a plain capital is lowered,
        /// since it says nothing about how the word is spelled.
        let shouldBe: String
        /// `shouldBe` came from the start of a sentence, so its capital was
        /// not the user's choice.
        let atSentenceStart: Bool

        /// Case-insensitive identity of the change.
        var key: String { WordFixMining.pairKey(heard: heard, shouldBe: shouldBe) }
    }

    static let maximumWordsPerSide = 3
    static let maximumSwapsPerDictation = 3
    static let maximumSpellingDifference = 0.67
    /// Box texts longer than this many words are documents, not messages.
    static let maximumWords = 2_000

    static func pairKey(heard: String, shouldBe: String) -> String {
        heard.lowercased() + "\u{1F}" + shouldBe.lowercased()
    }

    /// The substitutions worth counting in one captured dictation.
    ///
    /// - `inserted`: the text that was pasted.
    /// - `landed`: the box's value when the paste was first seen in it, if known.
    /// - `final`: the box's last value.
    /// - `otherTextInBox`: the box held more than the dictation when it landed.
    static func pairs(inserted: String, landed: String?, final: String, otherTextInBox: Bool) -> [Pair] {
        let insertedTokens = tokens(inserted)
        let finalTokens = tokens(final)
        guard !insertedTokens.isEmpty, !finalTokens.isEmpty,
              insertedTokens.count <= maximumWords, finalTokens.count <= maximumWords else { return [] }

        // Where the dictation sits in what is being compared, and whether the
        // ends of that comparison are the ends of the box.
        var base = insertedTokens
        var span = 0..<insertedTokens.count
        var endsAreBoxEdges = true
        if otherTextInBox {
            if let landed, case let landedTokens = tokens(landed), landedTokens.count <= maximumWords,
               let found = uniqueRange(of: insertedTokens.map(\.key), in: landedTokens.map(\.key)) {
                base = landedTokens
                span = found
            } else {
                // The box held other text, but not where: only changes with
                // dictated words kept on both sides can be trusted.
                endsAreBoxEdges = false
            }
        }

        let hunks = differences(base.map(\.key), finalTokens.map(\.key))

        // A rewrite, not a correction: too much of the dictation changed.
        let changedInSpan = hunks.reduce(0) { total, hunk in
            total + hunk.base.clamped(to: span).count
        }
        guard changedInSpan <= max(3, span.count / 2) else { return [] }

        var found: [Pair] = []
        for hunk in hunks {
            let b = hunk.base, f = hunk.final
            guard !b.isEmpty, !f.isEmpty else { continue }                  // pure insertion / deletion
            guard b.count <= maximumWordsPerSide, f.count <= maximumWordsPerSide else { continue }
            guard b.lowerBound >= span.lowerBound, b.upperBound <= span.upperBound else { continue }

            let keptBefore = b.lowerBound > 0
            let keptAfter = b.upperBound < base.count
            if !(keptBefore && keptAfter) {
                // At an end of the box, an unequal swap may be a swap plus
                // typing more; where the box's ends are unknown, never trust it.
                guard endsAreBoxEdges, b.count == f.count else { continue }
            }

            let heardKey = b.map { base[$0].key }.joined(separator: " ")
            let rightKey = f.map { finalTokens[$0].key }.joined(separator: " ")
            guard heardKey != rightKey else { continue }
            guard spellingDifference(heardKey, rightKey) <= maximumSpellingDifference else { continue }

            let heard = b.map { base[$0].display.lowercased() }.joined(separator: " ")
            var right = f.map { finalTokens[$0].display }
            let atStart = f.lowerBound == 0 || finalTokens[f.lowerBound - 1].endsSentence
            if atStart, let first = right.first, isPlainCapitalized(first) {
                right[0] = first.prefix(1).lowercased() + first.dropFirst()
            }
            found.append(Pair(heard: heard, shouldBe: right.joined(separator: " "), atSentenceStart: atStart))
        }
        guard found.count <= maximumSwapsPerDictation else { return [] }
        var seen = Set<String>()
        return found.filter { seen.insert($0.key).inserted }
    }

    /// True when every heard word is one of the most common English words —
    /// fixing it everywhere would also change it in normal text.
    static func isCommonWord(_ heard: String) -> Bool {
        let words = tokens(heard).map(\.key)
        return !words.isEmpty && words.allSatisfy { commonWords.contains($0) }
    }

    // MARK: - Words

    struct Token: Equatable, Sendable {
        /// Lower case, letters and digits only: what is compared.
        let key: String
        /// As written, without punctuation at either end.
        let display: String
        /// The written word ends a sentence (. ! ? or …).
        let endsSentence: Bool
    }

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let word = String(raw)
            let display = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = String(display.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.map(Character.init))
            guard !key.isEmpty else { return nil }
            let endsSentence = word.last.map { ".!?…".contains($0) } ?? false
            return Token(key: key, display: display, endsSentence: endsSentence)
        }
    }

    private static func isPlainCapitalized(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return word.dropFirst().allSatisfy { !$0.isUppercase }
    }

    /// Where `needle` occurs in `haystack`, if exactly once.
    static func uniqueRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var found: Range<Int>?
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<start + needle.count].elementsEqual(needle) {
            if found != nil { return nil }
            found = start..<start + needle.count
        }
        return found
    }

    // MARK: - Differences

    struct Hunk: Equatable, Sendable {
        let base: Range<Int>
        let final: Range<Int>
    }

    /// The runs of words that differ between `a` and `b`, between the words a
    /// longest common subsequence keeps.
    static func differences(_ a: [String], _ b: [String]) -> [Hunk] {
        let n = a.count, m = b.count
        // lengths[i][j] = LCS of a[i...] and b[j...]
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0, startI = 0, startJ = 0
        func close() {
            if startI < i || startJ < j { hunks.append(Hunk(base: startI..<i, final: startJ..<j)) }
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close()
                i += 1; j += 1
                startI = i; startJ = j
            } else if j < m, i == n || lengths[i][j + 1] >= lengths[i + 1][j] {
                j += 1
            } else {
                i += 1
            }
        }
        close()
        return hunks
    }

    /// Character edit distance over the longer length, spaces ignored: 0 is the
    /// same letters, 1 is nothing in common.
    static func spellingDifference(_ a: String, _ b: String) -> Double {
        let x = Array(a.filter { $0 != " " }), y = Array(b.filter { $0 != " " })
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        if x.isEmpty || y.isEmpty { return 1 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for p in 1...x.count {
            current[0] = p
            for q in 1...y.count {
                current[q] = min(previous[q] + 1, current[q - 1] + 1,
                                 previous[q - 1] + (x[p - 1] == y[q - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) / Double(longest)
    }

    /// The most frequent English words (compared without apostrophes). A fix
    /// for one of these would fire in ordinary sentences.
    static let commonWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "back", "be", "because", "been", "before", "being", "but", "by", "call", "can", "cant", "come",
        "could", "day", "did", "didnt", "do", "does", "doesnt", "done", "dont", "down", "each", "even",
        "find", "first", "for", "from", "get", "give", "go", "going", "good", "got", "had", "has", "have",
        "he", "her", "here", "him", "his", "how", "i", "id", "if", "ill", "im", "in", "into", "is",
        "isnt", "it", "its", "ive", "just", "know", "last", "let", "lets", "like", "look", "make",
        "many", "may", "me", "more", "most", "much", "my", "need", "new", "no", "not", "now", "of",
        "off", "oh", "ok", "okay", "on", "one", "only", "or", "other", "our", "out", "over", "put",
        "really", "right", "said", "same", "say", "see", "she", "should", "so", "some", "still",
        "such", "take", "than", "that", "thats", "the", "their", "them", "then", "there", "theres",
        "these", "they", "theyre", "thing", "think", "this", "those", "through", "time", "to", "too",
        "two", "up", "us", "use", "very", "want", "was", "way", "we", "well", "were", "what", "whats",
        "when", "where", "which", "while", "who", "why", "will", "with", "work", "would", "yeah",
        "yes", "you", "your", "youre",
    ]
}
