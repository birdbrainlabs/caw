import Foundation

/// Mines recognizer hints from the dictation log: recurring words that appear
/// in what the user SENT but never in what the recognizer HEARD — the words the
/// recognizer cannot reach on its own. Same logic as
/// Scripts/corpus-report.py --vocab. Foundation only, so Scripts/run-tests.sh
/// can test this exact file.
enum CorpusVocabulary {
    /// Every field is required, exactly as the app has always decoded a line;
    /// lines missing any of them are skipped.
    private struct Entry: Decodable {
        let timestamp: String
        let raw: String
        let cleaned: String
        let sent: String
        let wasEdited: Bool
        let destination: String
    }

    /// `text` is JSON lines, oldest first. For the Personal edition that is the
    /// archive followed by the live log, which is the untrimmed log in its
    /// original order — so trimming never changes the hints.
    static func mine(_ text: String, limit: Int = 40) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        let decoder = JSONDecoder()

        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                  entry.sent != entry.raw else { continue }
            let heard = Set(words(of: entry.raw).map(bare))
            for token in words(of: entry.sent) {
                let bareToken = bare(token)
                guard bareToken.count >= 3, !heard.contains(bareToken) else { continue }
                counts[bareToken, default: 0] += 1
                // Prefer the capitalized spelling when one has been seen —
                // these are mostly proper nouns.
                if display[bareToken] == nil || (token.first?.isUppercase == true && display[bareToken]?.first?.isUppercase != true) {
                    display[bareToken] = token
                }
            }
        }

        // Ties are broken alphabetically so the same log always gives the same
        // hints (dictionary order used to decide ties at the cut-off).
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }

    private static func words(of text: String) -> [String] {
        text.components(separatedBy: wordCharacters.inverted).filter { !$0.isEmpty }
    }

    private static func bare(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter }
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’"))
}
