// Suggested fixes learned from edits (Phase 2b), with made-up dictations:
// appended text and other text in the box are ignored, a real word swap is
// counted, two sightings make a suggestion, approve/reject behave, an existing
// word fix is never suggested again, common words are flagged, and the one-time
// backfill of the read-back log runs once.
//
// Works in a temporary folder; never touches Application Support.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct WordFixMiningTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func pairs(_ inserted: String, _ final: String, landed: String? = nil, other: Bool = false) -> [String] {
        WordFixMining.pairs(inserted: inserted, landed: landed, final: final, otherTextInBox: other)
            .map { "\($0.heard)→\($0.shouldBe)" }
    }

    static func main() throws {
        // MARK: The miner alone

        check(pairs("tell mark about the plan", "tell Mak about the plan") == ["mark→Mak"],
              "a one-word swap inside the dictation is found")
        check(pairs("tell mark about the plan", "tell mark about the plan and the budget too").isEmpty,
              "appended text is not a swap")
        check(pairs("tell mark about the plan", "so, tell mark about the plan").isEmpty,
              "text typed before the dictation is not a swap")
        check(pairs("tell mark about the plan", "tell about the plan").isEmpty,
              "a deleted word is not a swap")
        check(pairs("tell mark about it", "tell Mak about it and more").isEmpty == false
              && pairs("tell mark", "tell Mak about it").isEmpty,
              "a swap at the end followed by typing more is not trusted")
        check(pairs("Tell Mark, about the plan", "tell mark about the plan!").isEmpty,
              "punctuation and capitals alone are not swaps")
        check(pairs("I asked santa claude to help", "I asked send to Claude to help") == ["santa→send to"],
              "a one-for-two word swap is found (the kept word is not part of it)")
        check(pairs("we should ship the new build tonight", "they want a different plan for next week").isEmpty,
              "a rewrite is not a mishearing")
        check(pairs("the meeting is on friday", "the meeting is on budget").isEmpty,
              "a swap to an unrelated word is not a mishearing")

        // Other text already in the box.
        let landed = "Earlier notes here. tell mark about the plan"
        check(pairs("tell mark about the plan", "Earlier notes there. tell mark about the plan",
                    landed: landed, other: true).isEmpty,
              "edits to text that was already in the box are ignored")
        check(pairs("tell mark about the plan", "Earlier notes here. tell Mak about the plan",
                    landed: landed, other: true) == ["mark→Mak"],
              "a swap in the dictation is found when the box held other text")
        check(pairs("mark said yes", "Earlier notes here. Mak said yes", other: true).isEmpty,
              "without knowing where the dictation sat, a swap at its edge is ignored")
        check(pairs("then mark said yes", "Earlier notes here. then Mak said yes", other: true) == ["mark→Mak"],
              "without knowing where the dictation sat, a swap inside it is still found")

        let start = WordFixMining.pairs(inserted: "Mark said yes", landed: nil, final: "Mak said yes", otherTextInBox: false)
        check(start.first?.shouldBe == "mak" && start.first?.atSentenceStart == true,
              "a capital at the start of a sentence is not taken as the spelling")
        check(WordFixMining.isCommonWord("their") && !WordFixMining.isCommonWord("mark"),
              "common words are recognised")

        // MARK: Counting and suggesting

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("caw-mining-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fixesURL = folder.appendingPathComponent("word-fixes.json")
        try Data("""
        { "version": 1, "fixes": [ { "from": "kodak|kodex", "to": "codex", "capitalization": "always" } ] }
        """.utf8).write(to: fixesURL)
        let fixes = WordFixStore(fileURL: fixesURL)
        let suggestions = WordFixSuggestionStore(fileURL: folder.appendingPathComponent("word-fix-suggestions.json"),
                                                 wordFixes: fixes)
        let store = WordFixCandidateStore(fileURL: folder.appendingPathComponent("suggestion-candidates.json"),
                                          suggestions: suggestions, wordFixes: fixes)

        store.mine(inserted: "tell mark about the plan", landed: nil, final: "tell Mak about the plan",
                   otherTextInBox: false, app: "Claude")
        check(store.load().tally.candidates.values.first?.count == 1, "a real swap is counted")
        check(suggestions.pending.isEmpty, "one sighting is not a suggestion yet")

        store.mine(inserted: "ask mark now", landed: nil, final: "ask Mak now", otherTextInBox: false, app: "ChatGPT")
        check(suggestions.pending.map { "\($0.heard)→\($0.shouldBe)·\($0.count ?? 0)" } == ["mark→Mak·2"],
              "the second sighting makes a suggestion with its count")
        store.mine(inserted: "mark is here", landed: nil, final: "Mak is here", otherTextInBox: false, app: "Claude")
        check(suggestions.pending.first?.count == 3 && suggestions.pending.count == 1,
              "a third sighting updates the count, not a second suggestion")
        check(suggestions.pending.first?.shouldBe == "Mak",
              "sentence-start sightings keep the mid-sentence spelling")
        check(store.load().tally.candidates.values.first?.apps == ["Claude", "ChatGPT"],
              "the apps it was seen in are kept, once each")
        let saved = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(!saved.contains("about the plan") && !saved.contains("ask"),
              "the candidate file holds word pairs, not sentences")

        // Common word: still suggested, flagged.
        for _ in 0..<2 {
            store.mine(inserted: "put it over their now", landed: nil, final: "put it over there now",
                       otherTextInBox: false, app: "Claude")
        }
        let common = suggestions.pending.first { $0.heard == "their" }
        check(common?.commonWord == true, "a common heard word is suggested but flagged careful")

        // Approve moves it into word-fixes.json; later sightings are not re-suggested.
        let mark = suggestions.pending.first { $0.heard == "mark" }!
        try suggestions.approve(id: mark.id)
        check(fixes.loadFile()!.fixes.contains { $0.to == "Mak" }, "approve adds the fix to word-fixes.json")
        store.mine(inserted: "ping mark today", landed: nil, final: "ping Mak today", otherTextInBox: false, app: "Claude")
        check(!suggestions.pending.contains { $0.heard == "mark" }, "an approved pair is not suggested again")

        // Reject hides it for good, even as sightings continue.
        try suggestions.reject(id: common!.id)
        for _ in 0..<2 {
            store.mine(inserted: "put it over their now", landed: nil, final: "put it over There now",
                       otherTextInBox: false, app: "Claude")
        }
        check(!suggestions.pending.contains { $0.heard == "their" }, "a rejected pair never comes back")

        // An existing word fix is never suggested.
        for _ in 0..<3 {
            store.mine(inserted: "open kodak please", landed: nil, final: "open Codex please",
                       otherTextInBox: false, app: "Claude")
        }
        check(!suggestions.pending.contains { $0.heard == "kodak" }, "a pair already in word-fixes.json is not suggested")
        check(store.load().tally.candidates.values.allSatisfy { $0.heard != "kodak" },
              "a pair already in word-fixes.json is not even counted")

        // MARK: Backfill, once

        let logURL = folder.appendingPathComponent("readback-probe.jsonl")
        func line(_ stamp: String, _ inserted: String, _ final: String, captured: Bool = true) -> String {
            let record = ReadbackRecord(
                timestamp: stamp, bundleID: "test.app", appName: "Test", role: "AXTextArea", subrole: nil,
                readable: true, containsInserted: true, finalCaptured: captured, clearedBySend: captured,
                edited: true, editDistance: 1, secure: false, manualAccessibilityUsed: true, error: nil,
                endReason: captured ? "cleared" : "timeout", rangeOnly: false, otherTextInBox: false,
                insertedLength: inserted.count, finalLength: final.count, insertedText: inserted, finalText: final)
            return String(data: try! JSONEncoder().encode(record), encoding: .utf8)!
        }
        try ([
            line("2026-09-25T10:00:00Z", "call dana back", "call Dayna back"),
            line("2026-09-25T11:00:00Z", "tell dana hi", "tell Dayna hi"),
            line("2026-09-25T12:00:00Z", "dana dana", "Dayna Dayna", captured: false),
            line("2030-01-01T00:00:00Z", "email dana soon", "email Dayna soon"),
        ].joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        let cutoff = ISO8601DateFormatter().date(from: "2026-09-27T00:00:00Z")!
        let mined = store.backfillOnce(probeLog: logURL, before: cutoff)
        check(mined == 2, "backfill mines captured records from before this build only")
        check(suggestions.pending.first { $0.heard == "dana" }?.count == 2,
              "backfilled history reaches the threshold")
        check(store.backfillOnce(probeLog: logURL, before: cutoff) == nil, "backfill runs only once")

        if failures == 0 { print("word-fix mining: all passed") } else { exit(1) }
    }
}
