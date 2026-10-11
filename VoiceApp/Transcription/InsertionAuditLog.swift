import Foundation
import OSLog

/// Append-only local record of everything VoiceApp has put into another
/// application.
///
/// The app holds Accessibility access, so "what did it type, and where" has to be
/// answerable after the fact rather than taken on trust. The log records the
/// destination, the method and the size — deliberately **not** the text itself,
/// so the audit trail never becomes a transcript of everything you have dictated.
final class InsertionAuditLog {
    static let shared = InsertionAuditLog()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "AuditLog")
    private let queue = DispatchQueue(label: AppEdition.queueLabel("InsertionAuditLog"))

    private init() {}

    var fileURL: URL {
        AppEdition.supportDirectory.appendingPathComponent("insertions.log")
    }

    func record(method: String, destination: String, characters: Int, outcome: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        // padding(toLength:) truncates when the string is longer than the target,
        // which was silently shortening bundle identifiers in the log.
        let line = "\(stamp)  \(Self.pad(method, to: 13))  \(Self.pad(destination, to: 30))  "
            + "\(characters) characters  \(outcome)\n"

        queue.async { [fileURL, logger] in
            guard let data = line.data(using: .utf8) else { return }

            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    let header = """
                        # \(AppEdition.displayName) insertion log
                        # Every line records text \(AppEdition.displayName) placed into another application.
                        # The text itself is never recorded — only where it went and how large it was.

                        """
                    try (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
                }
            } catch {
                logger.error("Could not append to the insertion log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Creates the file if it has never been written, so opening it always shows
    /// something rather than failing.
    func prepareForViewing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        record(method: "—", destination: "—", characters: 0, outcome: "log created")
        queue.sync {}
    }
}
