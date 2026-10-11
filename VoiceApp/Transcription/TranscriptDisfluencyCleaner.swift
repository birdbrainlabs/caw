import Foundation

struct TranscriptDisfluencyCleaner: Sendable {
    var removesFillerWords = true
    var collapsesRepeatedWords = true
    var removesStutterFragments = true
    var capitalizesSentences = true
    var addsTerminalPunctuation = true
    var breaksRunOnSentences = true
    var removesClauseCommas = true
    var spellsOutSmallOrdinals = true
    var appliesOwnerSpellings = true
    /// The user's own word fixes, loaded from their word-fixes.json.
    var wordFixes: CompiledWordFixes = .empty

    func clean(_ transcript: String) -> String {
        var result = transcript

        if spellsOutSmallOrdinals {
            result = Self.spellingOutSmallOrdinals(in: result)
        }

        if removesStutterFragments {
            result = cleanInlineStutters(in: result)
            result = cleanSeparatedStutters(in: result)
            result = cleanTrailingOffStutters(in: result)
        }

        if removesFillerWords {
            result = Self.replace(Self.parentheticalFillerPattern, in: result, with: ",")
            result = Self.replace(Self.fillerPattern, in: result, with: "")
        }

        if collapsesRepeatedWords {
            result = collapseRepeatedPhrases(in: result)
            result = Self.replaceMatches(of: Self.punctuatedRepeatPattern, in: result) { match, source in
                Self.capture(1, from: match, in: source) ?? ""
            }
            result = Self.replaceMatches(of: Self.repeatedWordPattern, in: result) { match, source in
                Self.capture(1, from: match, in: source) ?? ""
            }
        }

        result = normalizeSpacing(in: result)

        if removesClauseCommas {
            // The macOS 26 engine commas every clause boundary; this user
            // deletes them. Measured from his last 120 sends: 43 commas
            // removed by hand, 5 added, and a third of the removals sat
            // directly before "and" or "but". His edits are the style guide.
            result = Self.replace(Self.clauseCommaPattern, in: result, with: " ")
        }

        if breaksRunOnSentences {
            result = Self.breakRunOnSentences(in: result)
        }

        if capitalizesSentences {
            result = Self.capitalizeSentences(in: result)
        }

        // After capitalisation on purpose: these rules decide case, and running
        // them earlier would have the sentence-capitaliser undo them.
        if appliesOwnerSpellings {
            result = wordFixes.apply(to: result)
        }

        if addsTerminalPunctuation {
            result = Self.addTerminalPunctuation(to: result)
        }

        return result
    }

    /// Splits run-on sentences where THIS user splits them.
    ///
    /// Mined 2026-08-15 from 318 corrected transcripts in the corpus: when he
    /// adds a period by hand, the next word is "I" (24×), "and" (14×), "so"
    /// (11×), "we", "let's", "if", "why", "what", or "please". Rules fire only
    /// deep into an unpunctuated stretch, never after a connective word, and
    /// "and"/"so" additionally need a clause-starting word after them — a
    /// missed break costs one manual period; a wrong one mangles a sentence,
    /// so every guard leans conservative. Deterministic and instant, unlike
    /// the on-device model, which can refuse, stall, or be evicted.
    static func breakRunOnSentences(in transcript: String) -> String {
        var words = transcript.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 10 else { return transcript }

        func core(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter }
        }

        let starters: Set<String> = ["i", "and", "so", "we", "lets", "if", "why", "what", "please"]

        // Words a new sentence does not begin after: mid-clause connectors,
        // prepositions, articles, auxiliaries, and verbs of saying/thinking.
        let blockedBefore: Set<String> = [
            "and", "but", "or", "so", "that", "which", "if", "when", "because", "as",
            "than", "then", "like", "to", "of", "in", "on", "at", "for", "with",
            "from", "by", "about", "into", "over", "after", "before", "while",
            "where", "a", "an", "the", "my", "your", "his", "her", "its", "our",
            "their", "me", "do", "does", "did", "can", "could", "will", "would",
            "should", "is", "are", "was", "am", "be", "been", "not", "dont",
            "didnt", "cant", "wont", "let", "make", "makes", "help", "tell",
            "told", "ask", "asked", "say", "said", "think", "know", "see", "want",
            "need", "mean", "guess", "hope", "wish", "sure", "how", "who", "why",
            "what", "maybe",
        ]

        // "and"/"so" only start a sentence when a clause plainly follows.
        let continuers: Set<String> = [
            "i", "we", "it", "the", "that", "this", "then", "you", "my", "a",
            "an", "im", "lets", "were", "maybe", "now", "theres",
        ]

        var distance = 0
        for index in words.indices {
            let previous = index > 0 ? words[index - 1] : ""
            if previous.hasSuffix(".") || previous.hasSuffix("?") || previous.hasSuffix("!") {
                distance = 0
            }

            let word = core(words[index])
            let remaining = words.count - index
            let previousEndsPlain = previous.last.map { $0.isLetter || $0.isNumber } ?? false

            if distance >= 9, remaining >= 3,
               starters.contains(word),
               previousEndsPlain,
               !blockedBefore.contains(core(previous)),
               word != "and" && word != "so"
                   || (index + 1 < words.count && continuers.contains(core(words[index + 1]))) {
                words[index - 1] = previous + "."
                distance = 0
            } else {
                distance += 1
            }
        }

        return words.joined(separator: " ")
    }

    /// "if it if it doesn't stop" and "ask it ask it to find" are the same stutter as
    /// a doubled word, just wider. Collapsing runs repeatedly so a phrase repeated
    /// three times reduces the whole way down.
    /// Apple's recognizer writes small ordinals as digits — "a 2nd folder", "the
    /// 1st thing you see" — where this speaker plainly said, and would write, the
    /// word. Larger ones are correct as digits and are left exactly as they are:
    /// "19th century" and "13th chapter" are not improved by spelling out.
    ///
    /// The boundary is measured, not chosen by taste. Across 1,985 transcripts
    /// the recognizer produced 46 ordinals; every one at ten or below reads
    /// wrong as digits, and every one above ten reads right. Same line standard
    /// English style draws, which is presumably why.
    ///
    /// Deliberately not the model's job. This is a fixed, reversible substitution
    /// with one correct answer, so it runs instantly here rather than costing a
    /// second and a chance of the model rewriting something else on the way past.
    private static let smallOrdinals: [String: String] = [
        "1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth",
        "5th": "fifth", "6th": "sixth", "7th": "seventh", "8th": "eighth",
        "9th": "ninth", "10th": "tenth",
    ]

    private static func spellingOutSmallOrdinals(in transcript: String) -> String {
        guard transcript.rangeOfCharacter(from: .decimalDigits) != nil else { return transcript }

        var result = transcript
        for (digits, word) in smallOrdinals {
            // Whole word only, so "51st" and "22nd" are never touched by the
            // rule for "1st" and "2nd" hiding at their ends.
            guard let pattern = try? NSRegularExpression(
                pattern: "(?<![0-9A-Za-z])\(digits)(?![0-9A-Za-z])",
                options: [.caseInsensitive]
            ) else { continue }
            // Lower case is safe: `capitalizesSentences` runs after this and
            // restores the capital if the word opened a sentence.
            result = replaceMatches(of: pattern, in: result) { _, _ in word }
        }
        return result
    }

    // Personal spellings used to be hard-coded here. They now live in each
    // user's word-fixes.json — see WordFixes.swift and WordFixStore.swift.

    private func collapseRepeatedPhrases(in transcript: String) -> String {
        var result = transcript

        for _ in 0..<4 {
            let next = Self.replaceMatches(of: Self.repeatedPhrasePattern, in: result) { match, source in
                guard let phrase = Self.capture(1, from: match, in: source) else { return "" }
                let whole = Self.capture(0, from: match, in: source) ?? phrase

                // A repeat spoken with a pause between it is only a stutter when the
                // words are ordinary ones. "New York, New York" is a place.
                if whole.contains(","), phrase.first?.isUppercase == true {
                    return whole
                }

                return phrase
            }
            if next == result { break }
            result = next
        }

        return result
    }

    /// A restart around a pause — "there... there's gotta be" — where the abandoned
    /// word is the beginning of the word that follows it.
    private func cleanTrailingOffStutters(in transcript: String) -> String {
        Self.replaceMatches(of: Self.trailingOffStutterPattern, in: transcript) { match, source in
            guard
                let abandoned = Self.capture(1, from: match, in: source),
                let resumed = Self.capture(2, from: match, in: source)
            else {
                return Self.capture(0, from: match, in: source) ?? ""
            }

            let foldedAbandoned = abandoned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let foldedResumed = resumed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            // Only drop the false start when the speaker plainly restarted the same
            // word. An unrelated word before the pause is real content.
            return foldedResumed.hasPrefix(foldedAbandoned) ? "" : (Self.capture(0, from: match, in: source) ?? "")
        }
    }

    /// Dictation that ends mid-thought — or that was cut off — arrives with no
    /// closing full stop.
    private static func addTerminalPunctuation(to transcript: String) -> String {
        guard let last = transcript.last else { return transcript }
        guard last.isLetter || last.isNumber else { return transcript }
        return transcript + "."
    }

    /// Dictation arrives with sentence capitalization that stops being correct once
    /// a leading "Uh," is removed, so the first letter of every sentence is restored.
    private static func capitalizeSentences(in transcript: String) -> String {
        replaceMatches(of: sentenceStartPattern, in: transcript) { match, source in
            guard let text = capture(0, from: match, in: source) else { return "" }
            return text.dropLast() + text.suffix(1).uppercased()
        }
    }

    private func cleanInlineStutters(in transcript: String) -> String {
        Self.replaceMatches(of: Self.inlineStutterPattern, in: transcript) { match, source in
            guard let token = Self.capture(0, from: match, in: source) else { return "" }
            let pieces = token.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            guard let word = pieces.last, pieces.count > 1 else { return token }

            let comparisonWord = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let fragmentsMatch = pieces.dropLast().allSatisfy { fragment in
                let comparisonFragment = fragment.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                return comparisonWord.hasPrefix(comparisonFragment)
            }

            return fragmentsMatch ? word : token
        }
    }

    private func cleanSeparatedStutters(in transcript: String) -> String {
        var result = transcript

        // Multiple fragments such as "w- w- want" are removed one pass at a time.
        for _ in 0..<8 {
            var removedFragment = false
            let next = Self.replaceMatches(of: Self.separatedStutterPattern, in: result) { match, source in
                guard
                    let fragment = Self.capture(1, from: match, in: source),
                    let word = Self.capture(2, from: match, in: source)
                else {
                    return Self.capture(0, from: match, in: source) ?? ""
                }

                let comparisonFragment = fragment.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                let comparisonWord = word.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )

                if comparisonWord.hasPrefix(comparisonFragment) {
                    removedFragment = true
                    return ""
                }

                return Self.capture(0, from: match, in: source) ?? ""
            }

            result = next
            if !removedFragment { break }
        }

        return result
    }

    private func normalizeSpacing(in transcript: String) -> String {
        var result = transcript
        result = Self.replace(Self.spaceBeforePunctuationPattern, in: result, with: "$1")
        result = Self.replace(Self.repeatedCommaPattern, in: result, with: ", ")
        result = Self.replace(Self.commaAfterSentenceEndPattern, in: result, with: "$1 ")
        result = Self.replace(Self.leadingCommaPattern, in: result, with: "")
        result = Self.replace(Self.leadingPunctuationPattern, in: result, with: "")
        result = Self.replace(Self.repeatedHorizontalSpacePattern, in: result, with: " ")
        result = Self.replace(Self.spaceBeforeNewlinePattern, in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in source: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: template
        )
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

    private static let fillerCore = #"u(?:h+m*|m+)"#
    private static let clauseCommaPattern = try! NSRegularExpression(
        pattern: #"(?i),\s+(?=(?:and|but)\b)"#
    )

    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}'’\-])"# + fillerCore + #"(?![\p{L}\p{N}'’\-])"#
    )
    private static let parentheticalFillerPattern = try! NSRegularExpression(
        pattern: #"(?i),\s*"# + fillerCore + #"\s*,"#
    )
    private static let repeatedPhrasePattern = try! NSRegularExpression(
        pattern: #"(?i)\b((?:\p{L}[\p{L}\p{N}'’]*)(?:[\t ]+\p{L}[\p{L}\p{N}'’]*){1,11})[\t ]*,?[\t ]+\1(?![\p{L}\p{N}'’])"#
    )
    // Three or more occurrences across punctuation — "a. A. A better way" — is a
    // stutter whether it is one word or several.
    private static let punctuatedRepeatPattern = try! NSRegularExpression(
        pattern: #"(?i)\b((?:\p{L}[\p{L}\p{N}'’]*)(?:[\t ]+\p{L}[\p{L}\p{N}'’]*){0,11})\b(?:[\t ]*[.,][\t ]+\1\b){2,}"#
    )
    private static let trailingOffStutterPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(\p{L}[\p{L}\p{N}'’]*)[\t ]*(?:\.{2,}|…)[\t ]+(?=(\p{L}[\p{L}\p{N}'’]*))"#
    )
    // Start of the text, or the first letter after a sentence ending.
    private static let sentenceStartPattern = try! NSRegularExpression(
        pattern: #"(?:\A|(?<=[.!?])[\t ]+|(?<=\n))\p{Ll}"#
    )
    private static let repeatedWordPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(\p{L}[\p{L}\p{N}]*(?:['’][\p{L}\p{N}]+)?)\b(?:[\t ]*,?[\t ]+\1\b)+"#
    )
    private static let inlineStutterPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:\p{L}{1,3}-){1,}\p{L}+\b"#
    )
    private static let separatedStutterPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(\p{L}{1,3})-[\t ]+(?=(\p{L}+)\b)"#
    )
    private static let spaceBeforePunctuationPattern = try! NSRegularExpression(pattern: #"[\t ]+([,.;:!?])"#)
    private static let repeatedCommaPattern = try! NSRegularExpression(pattern: #",(?:[\t ]*,)+[\t ]*"#)
    private static let commaAfterSentenceEndPattern = try! NSRegularExpression(pattern: #"([.!?])[\t ]*,[\t ]*"#)
    private static let leadingPunctuationPattern = try! NSRegularExpression(pattern: #"\A[\t ]*[.,;:!?]+[\t ]*"#)
    private static let leadingCommaPattern = try! NSRegularExpression(pattern: #"(?m)^[\t ]*,[\t ]*"#)
    private static let repeatedHorizontalSpacePattern = try! NSRegularExpression(pattern: #"[\t ]{2,}"#)
    private static let spaceBeforeNewlinePattern = try! NSRegularExpression(pattern: #"[\t ]+\n"#)
}
