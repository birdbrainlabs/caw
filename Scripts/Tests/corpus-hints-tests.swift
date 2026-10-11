// Proves the Personal edition's word hints do not change when old dictation is
// archived: hints mined from (archive + live log) after a retention pass equal
// hints mined from the untrimmed log. SYNTHETIC data in a temporary folder
// only — never the real Application Support files.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct CorpusHintsTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("caw-hints-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appendingPathComponent("corpus.jsonl")
        let archive = folder.appendingPathComponent(CorpusRetention.archiveFileName)

        let now = Date()
        let untrimmed = synthetic(now: now)
        try Data(untrimmed.utf8).write(to: live)
        let before = CorpusVocabulary.mine(untrimmed)
        precondition(before.count == 40, "fixture should saturate the 40-hint limit, got \(before.count)")

        for days in [120, 90, 30, 7] {
            let outcome = try CorpusRetention.apply(liveURL: live, archiveURL: archive,
                                                    cutoff: now.addingTimeInterval(-Double(days) * 86_400), archive: true)
            let liveText = try String(contentsOf: live, encoding: .utf8)
            let archiveText = String(decoding: try Gzip.decompress(Data(contentsOf: archive)), as: UTF8.self)
            let after = CorpusVocabulary.mine(archiveText + liveText)
            guard after == before else {
                print("FAIL after \(days)-day pass (\(outcome)):\n  before \(before)\n  after  \(after)"); exit(1)
            }
            if days == 30 {
                // Sanity: the live window alone WOULD have changed them.
                precondition(CorpusVocabulary.mine(liveText) != before, "fixture too weak: live-only hints already equal")
            }
        }
        print("PASS: hints mined from archive + live equal the untrimmed log's after 120/90/30/7-day passes (\(before.count) hints; live-only would differ)")
    }

    /// 200 days of entries, oldest first. Old corrections carry most of the
    /// vocabulary, with ties at the 40-hint cut-off and capitalised spellings
    /// that appear only late, so order and tie-breaking both matter.
    static func synthetic(now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let vocabulary = (0..<70).map { "word\(String(UnicodeScalar(97 + $0 % 26)!))\(String(UnicodeScalar(97 + $0 / 26)!))zz" }
        for index in 0..<3_000 {
            let age = 200 * 86_400 * Double(3_000 - index) / 3_000
            let stamp = formatter.string(from: now.addingTimeInterval(-age))
            let heardWord = vocabulary[next() % vocabulary.count]
            var sentWord = vocabulary[next() % (index < 2_000 ? vocabulary.count : 10)]
            if index > 2_500, next() % 2 == 0 { sentWord = sentWord.capitalized }
            let raw = "i said \(heardWord) today"
            let sent = next() % 5 == 0 ? raw : "I said \(sentWord) today, \(heardWord)"
            let entry: [String: Any] = ["timestamp": stamp, "raw": raw, "cleaned": raw, "sent": sent,
                                        "wasEdited": sent != raw, "destination": "(at cursor)"]
            let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
