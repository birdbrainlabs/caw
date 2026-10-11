import Darwin
import Foundation

/// Keeps the dictation log (corpus.jsonl) to a chosen age.
///
/// Entries older than the cutoff are either moved into a gzip archive beside
/// the log (`corpus-archive.jsonl.gz`, readable with any unzip tool) or
/// deleted. Moving is ordered so that a crash at any moment can never lose an
/// entry:
///
///  1. The new archive is written to a temporary file, flushed to disk, read
///     back, decompressed and compared — every line — before anything else
///     changes. Any mismatch stops here with both files untouched.
///  2. The verified archive replaces the old one in a single rename, and is
///     verified again in place.
///  3. Only then is the live log rewritten — to a temporary file, flushed, and
///     renamed over the original in one step.
///
/// A crash between 2 and 3 leaves the moved entries in both files; the next run
/// archives them again. Duplicates are possible, loss is not.
///
/// Lines whose timestamp cannot be read are always kept in the live log.
/// Foundation only, so Scripts/run-tests.sh can test this exact file.
enum CorpusRetention {
    static let archiveFileName = "corpus-archive.jsonl.gz"

    struct Outcome: Equatable {
        var kept = 0
        var archived = 0
        var deleted = 0
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadableArchive(String)
        case verificationFailed(String)

        var description: String {
            switch self {
            case .unreadableArchive(let why): return "the existing archive could not be read (\(why)); nothing was changed"
            case .verificationFailed(let why): return "the new archive did not verify (\(why)); nothing was changed"
            }
        }
    }

    /// Applies retention to `liveURL`. With `archive` true, old entries move to
    /// `archiveURL`; otherwise they are deleted. Returns what happened. When
    /// nothing is old enough, no file is touched.
    static func apply(liveURL: URL, archiveURL: URL, cutoff: Date, archive: Bool) throws -> Outcome {
        guard let data = FileManager.default.contents(atPath: liveURL.path) else { return Outcome() }

        let parser = ISO8601DateFormatter()
        var kept: [Data] = []
        var old: [Data] = []
        for line in lines(of: data) {
            if let stamp = timestamp(of: line, parser: parser), stamp < cutoff {
                old.append(line)
            } else {
                kept.append(line)
            }
        }
        guard !old.isEmpty else { return Outcome(kept: kept.count) }

        if archive {
            var plain = Data()
            var existingCount = 0
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                do {
                    let existing = try Gzip.decompress(Data(contentsOf: archiveURL))
                    existingCount = lines(of: existing).count
                    plain = existing
                    if let last = plain.last, last != 0x0A { plain.append(0x0A) }
                } catch {
                    throw Failure.unreadableArchive("\(error)")
                }
            }
            for line in old {
                plain.append(line)
                plain.append(0x0A)
            }
            let expectedCount = existingCount + old.count

            let compressed = try Gzip.compress(plain)
            let temporary = archiveURL.deletingLastPathComponent()
                .appendingPathComponent(".\(archiveURL.lastPathComponent).\(UUID().uuidString).tmp")
            try durableWrite(compressed, to: temporary)
            do {
                try verifyArchive(at: temporary, equals: plain, lineCount: expectedCount)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            try rename(temporary, over: archiveURL)
            try verifyArchive(at: archiveURL, equals: plain, lineCount: expectedCount)
        }

        var rewritten = Data()
        for line in kept {
            rewritten.append(line)
            rewritten.append(0x0A)
        }
        let temporary = liveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(liveURL.lastPathComponent).\(UUID().uuidString).tmp")
        try durableWrite(rewritten, to: temporary)
        try rename(temporary, over: liveURL)

        return Outcome(kept: kept.count, archived: archive ? old.count : 0, deleted: archive ? 0 : old.count)
    }

    /// Non-empty lines, without their newline.
    static func lines(of data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    private struct Stamp: Decodable { let timestamp: String }

    private static func timestamp(of line: Data, parser: ISO8601DateFormatter) -> Date? {
        guard let stamp = try? JSONDecoder().decode(Stamp.self, from: line) else { return nil }
        return parser.date(from: stamp.timestamp)
    }

    private static func verifyArchive(at url: URL, equals plain: Data, lineCount: Int) throws {
        let readBack: Data
        do {
            readBack = try Gzip.decompress(Data(contentsOf: url))
        } catch {
            throw Failure.verificationFailed("could not read it back: \(error)")
        }
        guard readBack == plain else { throw Failure.verificationFailed("contents differ") }
        let count = lines(of: readBack).count
        guard count == lineCount else { throw Failure.verificationFailed("\(count) lines, expected \(lineCount)") }
    }

    /// Writes and flushes to disk before returning.
    private static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Atomically replaces `destination` with `source` (same folder).
    private static func rename(_ source: URL, over destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: source)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}

/// Minimal gzip (RFC 1952) around Apple's raw-DEFLATE compressor, so archives
/// open with Archive Utility, `gunzip`, or `zcat`.
enum Gzip {
    enum Failure: Error { case notGzip, truncated, corrupt, checksumMismatch, compressionFailed }

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Failure.compressionFailed }
        let deflated: Data
        do {
            deflated = try (data as NSData).compressed(using: .zlib) as Data
        } catch {
            throw Failure.compressionFailed
        }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { throw Failure.notGzip }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw Failure.truncated }
            index += 2 + (Int(bytes[index]) | (Int(bytes[index + 1]) << 8))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count - 8 else { throw Failure.truncated }

        let body = Data(bytes[index..<(bytes.count - 8)])
        let inflated: Data
        do {
            inflated = try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Failure.corrupt
        }
        let trailer = Array(bytes[(bytes.count - 8)...])
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        guard crc == crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else {
            throw Failure.checksumMismatch
        }
        return inflated
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
