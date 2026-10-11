import Foundation
import OSLog

/// Loads the user's word fixes from `word-fixes.json` in this edition's
/// Application Support folder, and notices when the file is edited.
///
/// First launch without the file: an empty list with a short explanation.
/// A Personal build that bundles its own seed list
/// (Resources/word-fixes-personal.json, not part of the public source) copies
/// that in instead. The Beta edition always starts empty.
///
/// After that the file is only rewritten by the user's own edits in Settings ›
/// Words & Learning (`save`), atomically, keeping its `about` and `version`.
/// If it stops parsing, the last list that did parse keeps working (or, before
/// any has, the seed list), and `problem` says what is
/// wrong.
final class WordFixStore: @unchecked Sendable {
    static let shared = WordFixStore(
        fileURL: AppEdition.supportDirectory.appendingPathComponent(WordFixStore.fileName))

    /// Posted on the main thread after `save` changes the list.
    static let didChange = Notification.Name("WordFixStoreDidChange")

    static let fileName = "word-fixes.json"
    static let personalSeedResource = "word-fixes-personal"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "WordFixes")
    private let lock = NSLock()
    private var compiled: CompiledWordFixes?
    private var loadedStamp: Date?
    private var lastCheck = Date.distantPast
    private var _problem: String?

    let fileURL: URL

    /// `shared` uses this edition's Application Support folder; tests pass a
    /// temporary file.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// What is wrong with the file, if anything, in plain words.
    var problem: String? {
        lock.lock(); defer { lock.unlock() }
        return _problem
    }

    /// The fixes to apply now. Re-reads the file when its modification date
    /// changes, checking at most twice a second.
    var current: CompiledWordFixes {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if compiled == nil || now.timeIntervalSince(lastCheck) > 0.5 {
            lastCheck = now
            let stamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            if compiled == nil || stamp != loadedStamp {
                loadLocked(stamp: stamp)
            }
        }
        return compiled ?? .empty
    }

    /// Creates the file if it does not exist yet. Called at launch and before
    /// opening the file for editing.
    func ensureFileExists() {
        lock.lock(); defer { lock.unlock() }
        seedLocked()
    }

    /// The whole file as it is on disk now, for editing. Nil when it cannot be
    /// read or parsed (`problem` then says why).
    func loadFile() -> WordFixFile? {
        lock.lock(); defer { lock.unlock() }
        seedLocked()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? WordFixFile.decode(data)
    }

    /// Replaces the list with `fixes`, in this order, and applies it at once.
    /// Written atomically: a crash mid-save leaves the old file, never half of
    /// one. The file's `about` and `version` are kept.
    func save(_ fixes: [WordFix]) throws {
        lock.lock()
        let existing = (try? Data(contentsOf: fileURL)).flatMap { try? WordFixFile.decode($0) }
        let file = WordFixFile(about: existing?.about ?? Self.defaultAbout, version: existing?.version ?? 1, fixes: fixes)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            var data = try encoder.encode(file)
            data.append(0x0A)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lock.unlock()
            logger.error("Could not save word-fixes.json: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        loadLocked(stamp: nil)
        lastCheck = Date()
        lock.unlock()
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
        }
    }

    static let defaultAbout = "Word fixes: when the recognizer writes \"from\", your text says \"to\". Applied in order. Edit them in Settings › Words & Learning."

    // MARK: - Private

    private func seedLocked() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = Self.seedData()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .withoutOverwriting)
            logger.notice("Created word-fixes.json")
        } catch {
            logger.error("Could not create word-fixes.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadLocked(stamp: Date?) {
        seedLocked()
        loadedStamp = stamp ?? (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date

        do {
            let data = try Data(contentsOf: fileURL)
            let file = try WordFixFile.decode(data)
            let list = CompiledWordFixes(file.fixes)
            compiled = list
            _problem = list.invalidEntries.isEmpty ? nil
                : "Skipped \(list.invalidEntries.count) fix(es) that could not be read: \(list.invalidEntries.joined(separator: ", "))"
            logger.notice("Loaded \(list.count, privacy: .public) word fixes")
        } catch {
            _problem = "word-fixes.json could not be read (\(Self.describe(error))). Using the previous list."
            logger.error("word-fixes.json could not be read: \(Self.describe(error), privacy: .public)")
            if compiled == nil {
                compiled = Self.fallback()
            }
        }
    }

    /// Before any user file has parsed: the seed list, usually empty.
    private static func fallback() -> CompiledWordFixes {
        guard let file = try? WordFixFile.decode(seedData()) else { return .empty }
        return CompiledWordFixes(file.fixes)
    }

    /// The bundled seed list when a Personal build carries one; otherwise, in
    /// every edition, the empty list.
    private static func seedData() -> Data {
        #if !BETA
        if let url = Bundle.main.url(forResource: personalSeedResource, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        #endif
        return Data(emptyTemplate.utf8)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing \"\(key.stringValue)\"" }
        if case DecodingError.typeMismatch(_, let context) = error { return context.debugDescription }
        return error.localizedDescription
    }

    private static let emptyTemplate = """
    {
      "about": "Word fixes: when the recognizer writes \\"from\\", your text says \\"to\\". Applied in order. \\"from\\" ignores case; separate alternatives with |, write phrases with their spaces. capitalization: always (a name), matchHeard (capital only if the heard word had one), exact (written exactly as \\"to\\"). Example entry: { \\"from\\": \\"colonel\\", \\"to\\": \\"kernel\\", \\"capitalization\\": \\"always\\" }. Save the file and the next dictation uses it.",
      "version": 1,
      "fixes": []
    }

    """
}
