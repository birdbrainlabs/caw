// Tests the dictation-log retention step (VoiceApp/Transcription/CorpusRetention.swift)
// on SYNTHETIC data in a fresh temporary folder. It never opens the real
// ~/Library/Application Support files.
//
// The invariant that matters: entries before == live entries + archived entries
// after, line for line, and the archive is a standard gzip file.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct CorpusRetentionTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("caw-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        check(!folder.path.hasPrefix(real), "test folder must not be inside Application Support")

        let now = Date()
        let day: TimeInterval = 86_400
        let live = folder.appendingPathComponent("corpus.jsonl")
        let archive = folder.appendingPathComponent(CorpusRetention.archiveFileName)

        // 1,200 synthetic entries spread over 200 days, oldest first, plus lines
        // whose timestamp cannot be read. Text includes quotes, unicode and
        // escaped newlines, like real dictation.
        let original = synthetic(count: 1_200, spanDays: 200, now: now)
        try write(original, to: live)
        let before = CorpusRetention.lines(of: try Data(contentsOf: live))
        check(before.count == original.count, "fixture has \(original.count) lines")

        // --- Archive at 90 days ---------------------------------------------
        let cutoff90 = now.addingTimeInterval(-90 * day)
        let first = try CorpusRetention.apply(liveURL: live, archiveURL: archive, cutoff: cutoff90, archive: true)
        var liveAfter = CorpusRetention.lines(of: try Data(contentsOf: live))
        var archived = CorpusRetention.lines(of: try Gzip.decompress(Data(contentsOf: archive)))
        check(first.archived > 0 && first.kept > 0 && first.deleted == 0, "90-day archive moved some and kept some: \(first)")
        check(before.count == liveAfter.count + archived.count,
              "count before (\(before.count)) == live (\(liveAfter.count)) + archive (\(archived.count))")
        check(sorted(before) == sorted(liveAfter + archived), "every original line is in exactly one file, byte for byte")
        check(archived.allSatisfy { stamp($0).map { $0 < cutoff90 } ?? false }, "archive holds only entries older than 90 days")
        check(liveAfter.allSatisfy { stamp($0).map { $0 >= cutoff90 } ?? true }, "live keeps recent and unreadable-timestamp lines")
        check(liveAfter.contains { stamp($0) == nil }, "lines without a readable timestamp stay in the live log")
        check(liveAfter == before.filter { line in stamp(line).map { $0 >= cutoff90 } ?? true },
              "live log keeps its original order")

        // The archive is standard gzip: the system tool agrees.
        let systemPlain = try run("/usr/bin/gzip", ["-dc", archive.path])
        check(systemPlain == (try Gzip.decompress(Data(contentsOf: archive))), "system gzip decodes the archive identically")
        check((try run("/usr/bin/gzip", ["-t", archive.path])).isEmpty, "gzip -t passes")

        // --- Idempotent: nothing old enough, nothing touched -------------------
        let liveStamp = try modified(live), archiveStamp = try modified(archive)
        Thread.sleep(forTimeInterval: 1.1)
        let again = try CorpusRetention.apply(liveURL: live, archiveURL: archive, cutoff: cutoff90, archive: true)
        check(again == CorpusRetention.Outcome(kept: liveAfter.count), "second run at the same cutoff moves nothing")
        check(try modified(live) == liveStamp && (try modified(archive)) == archiveStamp, "and rewrites neither file")

        // --- New entries arrive, then a tighter cutoff appends to the archive -
        let fresh = synthetic(count: 50, spanDays: 1, now: now, idOffset: 10_000)
        let handle = try FileHandle(forWritingTo: live)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(fresh.joined(separator: "\n").utf8 + [0x0A]))
        try handle.close()
        let beforeSecond = CorpusRetention.lines(of: try Data(contentsOf: live))
        let archivedBefore = archived
        let second = try CorpusRetention.apply(liveURL: live, archiveURL: archive,
                                               cutoff: now.addingTimeInterval(-30 * day), archive: true)
        liveAfter = CorpusRetention.lines(of: try Data(contentsOf: live))
        archived = CorpusRetention.lines(of: try Gzip.decompress(Data(contentsOf: archive)))
        check(second.archived > 0, "30-day pass archived more: \(second)")
        check(beforeSecond.count + archivedBefore.count == liveAfter.count + archived.count,
              "second pass: live+archive before (\(beforeSecond.count + archivedBefore.count)) == after (\(liveAfter.count + archived.count))")
        check(Array(archived.prefix(archivedBefore.count)) == archivedBefore, "earlier archive is preserved, new entries appended")
        check(sorted(before + fresh.map { Data($0.utf8) }) == sorted(liveAfter + archived), "still no line lost or altered")

        // --- A corrupt archive stops everything --------------------------------
        let corruptFolder = folder.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptLive = corruptFolder.appendingPathComponent("corpus.jsonl")
        let corruptArchive = corruptFolder.appendingPathComponent(CorpusRetention.archiveFileName)
        try write(original, to: corruptLive)
        try Data("not a gzip file".utf8).write(to: corruptArchive)
        let liveBytes = try Data(contentsOf: corruptLive)
        var threw = false
        do { _ = try CorpusRetention.apply(liveURL: corruptLive, archiveURL: corruptArchive, cutoff: cutoff90, archive: true) }
        catch { threw = true }
        check(threw, "an unreadable archive is an error")
        check(try Data(contentsOf: corruptLive) == liveBytes, "live log untouched when the archive is unreadable")
        check(try Data(contentsOf: corruptArchive) == Data("not a gzip file".utf8), "unreadable archive left as it was")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: corruptFolder.path).filter { $0.hasSuffix(".tmp") }
        check(leftovers.isEmpty, "no temporary files left behind")

        // --- Delete mode (Beta default) --------------------------------------
        let deleteFolder = folder.appendingPathComponent("delete", isDirectory: true)
        try FileManager.default.createDirectory(at: deleteFolder, withIntermediateDirectories: true)
        let deleteLive = deleteFolder.appendingPathComponent("corpus.jsonl")
        let deleteArchive = deleteFolder.appendingPathComponent(CorpusRetention.archiveFileName)
        try write(original, to: deleteLive)
        let cutoff30 = now.addingTimeInterval(-30 * day)
        let deleted = try CorpusRetention.apply(liveURL: deleteLive, archiveURL: deleteArchive, cutoff: cutoff30, archive: false)
        let deleteAfter = CorpusRetention.lines(of: try Data(contentsOf: deleteLive))
        check(deleted.deleted > 0 && deleted.archived == 0, "delete mode deletes: \(deleted)")
        check(deleteAfter == before.filter { line in stamp(line).map { $0 >= cutoff30 } ?? true }, "delete mode keeps exactly the recent lines")
        check(!FileManager.default.fileExists(atPath: deleteArchive.path), "delete mode creates no archive")

        // --- Our gzip reader accepts the system tool's output (with a file name header)
        let sample = folder.appendingPathComponent("sample.txt")
        try Data("hello\nworld\n".utf8).write(to: sample)
        _ = try run("/usr/bin/gzip", ["-k", "-N", sample.path])
        check(try Gzip.decompress(Data(contentsOf: folder.appendingPathComponent("sample.txt.gz"))) == Data("hello\nworld\n".utf8),
              "reads gzip files written by /usr/bin/gzip")

        print("PASS: corpus retention — \(checks) checks; archive and delete modes keep every entry accounted for (synthetic data only)")
    }

    // MARK: - Helpers

    static func synthetic(count: Int, spanDays: Double, now: Date, idOffset: Int = 0) -> [String] {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for index in 0..<count {
            let age = spanDays * 86_400 * Double(count - index) / Double(count)
            let stamp = formatter.string(from: now.addingTimeInterval(-age))
            let id = index + idOffset
            let raw = "entry \(id) said \"hi\" — café ☕️ line\\nbreak"
            let entry: [String: Any] = ["timestamp": stamp, "raw": raw, "cleaned": raw + ".", "sent": raw + ".",
                                        "wasEdited": false, "destination": "cursor"]
            let json = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
            lines.append(String(decoding: json, as: UTF8.self))
            if index % 97 == 0 { lines.append(#"{"raw":"no timestamp \#(id)"}"#) }
            if index % 211 == 0 { lines.append("not json at all \(id)") }
        }
        return lines
    }

    static func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    static func stamp(_ line: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let text = object["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    static func sorted(_ lines: [Data]) -> [Data] {
        lines.sorted { $0.lexicographicallyPrecedes($1) }
    }

    static func modified(_ url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        check(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        return output
    }
}
