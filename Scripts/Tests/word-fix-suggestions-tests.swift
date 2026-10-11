// Suggested word fixes, against the fixture in Scripts/Tests/fixtures: approving
// moves a suggestion into word-fixes.json (and the cleaner uses it at once);
// rejecting hides it for good, even if the same change is suggested again.
// Also: saving from the Settings editor keeps the list's order and meaning.
//
// Works in a temporary folder; never touches Application Support.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct WordFixSuggestionsTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func main() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("Scripts/Tests/fixtures/word-fix-suggestions.json")
        let seed = repo.appendingPathComponent("Scripts/Tests/fixtures/word-fixes-sample.json")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("caw-suggestions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fixesURL = folder.appendingPathComponent("word-fixes.json")
        let suggestionsURL = folder.appendingPathComponent("word-fix-suggestions.json")
        try FileManager.default.copyItem(at: seed, to: fixesURL)
        try FileManager.default.copyItem(at: fixture, to: suggestionsURL)

        let fixes = WordFixStore(fileURL: fixesURL)
        let suggestions = WordFixSuggestionStore(fileURL: suggestionsURL, wordFixes: fixes)
        let before = fixes.loadFile()!.fixes

        // Editor save round trip: same list saved back is the same list, same output.
        var cleaner = TranscriptDisfluencyCleaner()
        cleaner.wordFixes = fixes.current
        let sample = "i asked clawed about the palate in bird brain and zurich"
        let expected = cleaner.clean(sample)
        try fixes.save(before)
        cleaner.wordFixes = fixes.current
        check(fixes.loadFile()!.fixes == before, "saving the list unchanged keeps every entry and its order")
        check(cleaner.clean(sample) == expected, "saving the list unchanged keeps dictation output identical")
        check(fixes.loadFile()!.about?.contains("Word fixes") == true, "saving keeps the file's about text")

        // A blank row being typed is ignored, never matched everywhere.
        try fixes.save(before + [WordFix(from: "", to: "X", capitalization: .exact)])
        cleaner.wordFixes = fixes.current
        check(cleaner.clean(sample) == expected, "an empty 'heard' row does nothing")
        try fixes.save(before)

        check(suggestions.pending.map(\.id) == ["fixture-approve", "fixture-reject"],
              "pending shows the two waiting suggestions, not the old rejected one")

        // Approve.
        let approved = try suggestions.approve(id: "fixture-approve")
        let after = fixes.loadFile()!.fixes
        check(after.count == before.count + 1 && after.last == approved, "approve appends the fix to word-fixes.json")
        check(approved.from == "grate" && approved.to == "great" && approved.capitalization == .matchHeard,
              "approved fix: heard → should be, capital only if heard with one")
        check(!suggestions.pending.contains { $0.id == "fixture-approve" }, "approved suggestion leaves the list")
        cleaner.wordFixes = fixes.current
        check(cleaner.clean("the pixel art looks grate today") == "The pixel art looks great today.",
              "the cleaner uses the approved fix straight away")

        // Reject.
        try suggestions.reject(id: "fixture-reject")
        check(suggestions.pending.isEmpty, "rejected suggestion is hidden")
        check(fixes.loadFile()!.fixes.count == before.count + 1, "rejecting adds nothing to word-fixes.json")
        let reloaded = WordFixSuggestionStore(fileURL: suggestionsURL, wordFixes: fixes)
        check(reloaded.pending.isEmpty, "still hidden after reloading the file")
        let again = try reloaded.add(WordFixSuggestion(heard: "Fable", shouldBe: "Fable", count: 9))
        check(!again && reloaded.pending.isEmpty, "the same change suggested again stays hidden (heard ignores case)")

        // New suggestions: added once; not re-suggested once they are fixes.
        check(try reloaded.add(WordFixSuggestion(heard: "Roost", shouldBe: "Roost")) == true, "a new change is added")
        check(try reloaded.add(WordFixSuggestion(heard: "roost", shouldBe: "Roost")) == false, "the same change is not added twice")
        check(try reloaded.add(WordFixSuggestion(heard: "grate", shouldBe: "great")) == false,
              "a change that is already a word fix is not suggested")
        let named = try reloaded.approve(id: reloaded.pending.first!.id)
        check(named.capitalization == .always, "a suggestion written with a capital becomes an always-capitalised name")
        check(WordFixSuggestionStore.fix(from: WordFixSuggestion(heard: "c++", shouldBe: "C")).from == "c\\+\\+",
              "heard words are matched literally, not as a pattern")

        print(failures == 0 ? "word-fix suggestions: all passed" : "word-fix suggestions: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
