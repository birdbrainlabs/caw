// The read-back test's bookkeeping, fed made-up polls: when does a watch call
// the text readable, captured, cleared by a send, and edited — and how far.
// No Accessibility, no files.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct ReadbackTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func run(_ inserted: String, _ polls: [ReadbackObservation]) -> ReadbackTracker {
        var tracker = ReadbackTracker(inserted: inserted)
        for poll in polls where !tracker.isFinished { tracker.observe(poll) }
        if !tracker.isFinished { tracker.observe(.timedOut) }
        return tracker
    }

    static func main() {
        let inserted = "I asked Claude about the sprite."

        // Pasted, left alone, sent with Return: captured, not edited.
        var t = run(inserted, [.value(""), .value(inserted + "\n"), .value(inserted), .value("")])
        check(t.readable && t.containsInserted, "readable, and the dictation was seen")
        check(t.clearedBySend && t.finalCaptured, "emptying the box counts as sent and captures the final text")
        check(!t.edited && t.editDistance == 0, "untouched text is not an edit (trailing newline ignored)")

        // Edited, then sent.
        t = run(inserted, [.value(inserted), .value("I asked Claude about the sprites!"), .value("")])
        check(t.finalCaptured && t.edited, "an edit before sending is captured")
        check(t.editDistance == 2, "edit distance counts characters changed (got \(String(describing: t.editDistance)))")
        check(t.lastNonEmpty == "I asked Claude about the sprites!", "keeps the last non-empty value before clearing")

        // Whitespace differences are not edits and do not hide the dictation.
        t = run("hello  there\nfriend", [.value("hello there\u{00A0}friend "), .focusLeft])
        check(t.containsInserted && t.finalCaptured && !t.edited, "whitespace-only differences are ignored")

        // Box already had text: dictation found inside it, and flagged.
        t = run("second part.", [.value("First part. second part."), .focusLeft])
        check(t.containsInserted && t.otherTextInBox, "dictation found inside existing text, flagged as other text")
        check(t.edited, "final differs from inserted when other text was there (as specified)")

        // A new dictation supersedes the watch: not final.
        t = run(inserted, [.value(inserted), .value(inserted + " more"), .newDictation])
        check(!t.finalCaptured && !t.edited && t.editDistance == nil, "a new dictation leaves the final text uncaptured")

        // Timeout: not final.
        t = run(inserted, [.value(inserted)])
        check(!t.finalCaptured && t.endReason == .timeout, "running out the 90 seconds is not a capture")

        // Unreadable from the start: stops at once, notes a range-only box.
        t = run(inserted, [.valueUnavailable(rangeAvailable: true, error: "value: noValue"), .value(inserted)])
        check(!t.readable && t.rangeOnly && t.endReason == .unreadable, "unreadable box stops immediately, range-only noted")
        check(t.error == "value: noValue", "the read error is kept")

        // Readable, then the box disappears (Electron rebuilding its input on send).
        t = run(inserted, [.value(inserted), .valueUnavailable(rangeAvailable: false, error: "value: invalidUIElement")])
        check(t.finalCaptured && t.endReason == .boxGone, "a box that disappears after being read counts as captured")

        // Paste never showed up, box stays empty: nothing captured, not cleared.
        t = run(inserted, [.value(""), .value(""), .focusLeft])
        check(t.readable && !t.containsInserted && !t.clearedBySend && !t.finalCaptured, "an empty box that never held the text is not a send")

        // Edit distance basics.
        check(ReadbackText.editDistance("kitten", "sitting") == 3, "kitten → sitting is 3")
        check(ReadbackText.editDistance("", "abc") == 3, "empty → abc is 3")
        check(ReadbackText.editDistance(String(repeating: "a", count: 5000), String(repeating: "b", count: 5000)) == nil,
              "very long texts are not compared")

        // Records round-trip through the log format, and the table adds up.
        let records: [ReadbackRecord] = [
            run(inserted, [.value(inserted), .value("")]).record(timestamp: "t1", bundleID: "com.anthropic.claudefordesktop", appName: "Claude", role: "AXTextArea", subrole: nil, manualAccessibilityUsed: true),
            run(inserted, [.value(inserted), .value(inserted + " edited"), .value("")]).record(timestamp: "t2", bundleID: "com.anthropic.claudefordesktop", appName: "Claude", role: "AXTextArea", subrole: nil, manualAccessibilityUsed: true),
            run(inserted, [.value(inserted), .newDictation]).record(timestamp: "t3", bundleID: "com.anthropic.claudefordesktop", appName: "Claude", role: "AXTextArea", subrole: nil, manualAccessibilityUsed: true),
            run(inserted, [.valueUnavailable(rangeAvailable: false, error: "x")]).record(timestamp: "t4", bundleID: "com.google.Chrome", appName: "Chrome", role: "AXTextArea", subrole: nil, manualAccessibilityUsed: false),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonl = records.map { String(data: try! encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\nnot json\n"
        let parsed = ReadbackResults.parse(jsonl)
        check(parsed == records, "log lines round-trip, junk lines skipped")
        check(!jsonl.contains("insertedText") && !jsonl.contains(inserted),
              "a record carries no text unless the Personal probe adds it")

        let table = ReadbackResults.summarize(parsed)
        check(table.map(\.appName) == ["Claude", "Chrome"], "most-used app first")
        let claude = table[0]
        check(claude.dictations == 3 && claude.readable == 3 && claude.finalCaptured == 2 && claude.edited == 1,
              "per-app counts")
        check(claude.readablePercent == "100%" && claude.capturedPercent == "67%" && claude.editedPercent == "50%",
              "percentages (edited is out of captured)")
        check(table[1].readablePercent == "0%" && table[1].editedPercent == "—", "no captures shows a dash, not 0%")

        print(failures == 0 ? "readback: all passed" : "readback: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
