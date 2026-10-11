import AppKit
import Foundation
import OSLog

/// Records what VoiceApp produced next to what the user actually sent.
///
/// Every correction made in the review card is a labelled training example — in
/// the user's own voice, vocabulary and subject matter — which is the one kind of
/// data that cannot be bought or recovered later. Unedited sends are recorded too,
/// since "this needed no correction" is just as useful a signal.
///
/// Unlike the insertion audit log, this file *does* contain your dictation. That is
/// its purpose, so it is listed plainly in the menu and can be turned off or
/// deleted at any time.
@MainActor
final class TrainingCorpus: ObservableObject {
    static let shared = TrainingCorpus()

    private static let enabledDefaultsKey = "TrainingCorpusEnabled"
    private static let retentionDaysDefaultsKey = "CorpusRetentionDays"
    private static let archivesDefaultsKey = "CorpusArchivesOldEntries"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey) }
    }

    /// How many days of dictation the live log keeps; 0 keeps everything.
    /// Personal default: 90 days, archived. Beta default: 30 days, deleted.
    @Published var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: Self.retentionDaysDefaultsKey)
            applyRetention()
        }
    }

    /// Older entries move into corpus-archive.jsonl.gz instead of being deleted.
    @Published var archivesOldEntries: Bool {
        didSet {
            UserDefaults.standard.set(archivesOldEntries, forKey: Self.archivesDefaultsKey)
            applyRetention()
        }
    }

    static let retentionChoices = [0, 90, 30]
    private var lastRetentionRun = Date.distantPast

    /// Words the user typed into sends that the recognizer never produced —
    /// his proper nouns and jargon, mined from the corpus. Fed to the
    /// recognizer as vocabulary hints, so every correction he makes teaches
    /// dictation the word he actually meant. Refreshed after every send.
    @Published private(set) var minedVocabulary: [String] = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "Corpus")
    private let queue = DispatchQueue(label: AppEdition.queueLabel("TrainingCorpus"))

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }
        let defaults = UserDefaults.standard
        retentionDays = defaults.object(forKey: Self.retentionDaysDefaultsKey) as? Int ?? (AppEdition.isBeta ? 30 : 90)
        archivesOldEntries = defaults.object(forKey: Self.archivesDefaultsKey) as? Bool ?? !AppEdition.isBeta
        // Same serial queue: retention finishes before the vocabulary is mined,
        // so the hints come from the live window.
        applyRetention()
        refreshMinedVocabulary()
    }

    var archiveURL: URL {
        AppEdition.supportDirectory.appendingPathComponent(CorpusRetention.archiveFileName)
    }

    /// Moves (or deletes) entries older than the retention window. Runs at
    /// launch, when the setting changes, and at most once a day after that.
    func applyRetention() {
        lastRetentionRun = Date()
        let days = retentionDays
        guard days > 0 else { return }
        let archive = archivesOldEntries
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        queue.async { [fileURL, archiveURL, logger] in
            do {
                let outcome = try CorpusRetention.apply(liveURL: fileURL, archiveURL: archiveURL, cutoff: cutoff, archive: archive)
                if outcome.archived > 0 || outcome.deleted > 0 {
                    logger.notice("Retention (\(days, privacy: .public) days): kept \(outcome.kept, privacy: .public), archived \(outcome.archived, privacy: .public), deleted \(outcome.deleted, privacy: .public)")
                }
            } catch {
                logger.error("Retention skipped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Reads the corpus off the main thread and extracts recurring words that
    /// appear in what the user SENT but never in what the recognizer HEARD.
    /// Those are precisely the words the recognizer cannot reach on its own.
    /// Same logic as Scripts/corpus-report.py --vocab, living in the app.
    func refreshMinedVocabulary() {
        queue.async { [fileURL, archiveURL, logger] in
            guard let data = try? Data(contentsOf: fileURL),
                  let live = String(data: data, encoding: .utf8) else { return }

            // Personal keeps its archived entries in the hints, so trimming the
            // live log never changes them. Beta mines the live window only.
            var text = live
            #if !BETA
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                if let archived = try? Gzip.decompress(Data(contentsOf: archiveURL)),
                   let archivedText = String(data: archived, encoding: .utf8) {
                    text = archivedText + (archivedText.hasSuffix("\n") || archivedText.isEmpty ? "" : "\n") + live
                } else {
                    logger.error("Could not read the corpus archive; mining the live log only")
                }
            }
            #endif

            let vocabulary = CorpusVocabulary.mine(text)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.minedVocabulary = vocabulary
                // The count only — the words are the user's vocabulary and
                // stay out of the system log.
                self.logger.notice("Mined \(vocabulary.count, privacy: .public) vocabulary hints from the corpus")
            }
        }
    }

    var fileURL: URL {
        AppEdition.supportDirectory.appendingPathComponent("corpus.jsonl")
    }

    private struct Entry: Codable {
        let timestamp: String
        /// Exactly what the recognizer returned.
        let raw: String
        /// After the deterministic cleanup pass.
        let cleaned: String
        /// What the user actually sent, after any edit.
        let sent: String
        let wasEdited: Bool
        let destination: String
    }

    func record(raw: String, cleaned: String, sent: String, destination: String) {
        guard isEnabled else { return }
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            raw: raw,
            cleaned: cleaned,
            sent: sent,
            wasEdited: sent != cleaned,
            destination: destination
        )

        queue.async { [fileURL, logger] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                var data = try encoder.encode(entry)
                data.append(0x0A)

                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                logger.error("Could not append to the training corpus: \(error.localizedDescription, privacy: .public)")
            }
        }

        // The vocabulary is mined once at launch. Re-reading the whole corpus
        // after every send cost 0.4–1.3s at 9,860 lines and grew with each one.

        if Date().timeIntervalSince(lastRetentionRun) > 86_400 {
            applyRetention()
        }
    }

    func revealInFinder() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    /// Deletes the log and its archive. Queued behind any pending write or
    /// retention pass so nothing is recreated after the delete.
    func deleteEverything() {
        queue.async { [fileURL, archiveURL, logger] in
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: archiveURL)
            logger.notice("Training corpus deleted")
        }
    }
}
