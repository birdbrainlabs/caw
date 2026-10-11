import AppKit
import ApplicationServices
import OSLog

/// The read-back test (Phase 2a). A measurement, and nothing else: it changes
/// nothing the user sees and nothing about how text is inserted.
///
/// Since the review card went (2026-08-21) the app pastes into the
/// destination's own text box and never sees what the user does to the words
/// there, so the corrections loop has had no signal. Before building anything
/// that learns from those edits, this finds out which apps will let the text be
/// read back at all.
///
/// After each insertion it looks at the focused element of the app the text
/// went into and polls that element's value every half second for up to 90
/// seconds — stopping as soon as a read fails, focus leaves the element, the
/// box empties (the message was sent) or a new dictation starts. One line per
/// dictation goes to `readback-probe.jsonl`.
///
/// Limits, enforced here and by `Scripts/verify-capabilities.sh`:
/// - Password fields are never read: `AXSecureTextField` is logged as "secure"
///   and the watch ends before any value is asked for.
/// - Only text-entry elements are read (text area, text field, combo box,
///   search field). Anything else is logged by role and left alone.
/// - The only attribute ever written is `AXManualAccessibility`, which Electron
///   documents for assistive software: once per app run for most apps, and for
///   Electron/Chromium apps (`ChromiumAppDetection`) again on every dictation
///   until the app accepts it.
/// - Electron builds its tree a beat after being asked, so when the focused
///   element is missing (or not a text box yet) right after the paste, the
///   lookup is retried every quarter second for about a second.
/// - Every call runs on this probe's own queue with a quarter-second
///   Accessibility timeout, so a hung app cannot stall dictation.
/// - The Beta edition records no text in this log — only whether reading
///   worked — and the test ships switched off there.
/// - When the final text was captured, small word swaps in it are handed to
///   `WordFixCandidateStore`, which keeps only the word pairs (both editions).
final class ReadbackProbe: @unchecked Sendable {
    static let shared = ReadbackProbe()

    static let enabledKey = "ReadbackProbeEnabled"
    static let fileName = "readback-probe.jsonl"

    /// Personal: on unless switched off. Beta: off unless switched on.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? !AppEdition.isBeta }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Text longer than this is a document, not a message; its text is not kept.
    private static let maximumStoredCharacters = 4_000
    private static let pollInterval: TimeInterval = 0.5
    private static let watchDuration: TimeInterval = 90
    private static let messagingTimeout: Float = 0.25
    private static let textEntryRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]
    private static let secureRole = "AXSecureTextField"
    /// Focus lookups after the paste: the first at once, then every
    /// `focusRetryInterval`, so the last is about a second later.
    private static let focusAttempts = 5
    private static let focusRetryInterval: TimeInterval = 0.25

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "Readback")
    private let queue = DispatchQueue(label: AppEdition.queueLabel("ReadbackProbe"), qos: .utility)

    /// Bumped by every new dictation and every new watch; a watch that sees a
    /// different number has been superseded.
    private let generationLock = NSLock()
    private var generation = 0

    /// What each running app answered to AXManualAccessibility. Queue-only.
    private var manualAccessibilityByProcess: [pid_t: AXError] = [:]
    /// `ChromiumAppDetection` per app bundle ("" = not Chromium). Queue-only.
    private var chromiumMarkerByBundle: [String: String] = [:]

    private init() {}

    var fileURL: URL {
        AppEdition.supportDirectory.appendingPathComponent(Self.fileName)
    }

    // MARK: - Called by TextInsertionController

    /// A new dictation is starting. Cheap: this runs inside the Fn callback.
    func dictationStarted() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }

    /// Text was just pasted into `application`. Starts watching its focused box.
    func watch(inserted text: String, in application: NSRunningApplication) {
        guard Self.isEnabled, !text.isEmpty else { return }
        let pid = application.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let bundleID = application.bundleIdentifier ?? application.localizedName ?? "unknown"
        let appName = application.localizedName ?? bundleID
        let bundleURL = application.bundleURL

        generationLock.lock()
        generation += 1
        let mine = generation
        generationLock.unlock()

        queue.async { [self] in
            begin(text: text, pid: pid, bundleID: bundleID, bundleURL: bundleURL, appName: appName, generation: mine)
        }
    }

    // MARK: - Results

    /// Everything recorded so far. Reads the file off the main thread.
    func loadRecords(completion: @escaping @MainActor ([ReadbackRecord]) -> Void) {
        queue.async { [fileURL] in
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let records = ReadbackResults.parse(text)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(records) } }
        }
    }

    func clearResults(completion: @escaping @MainActor () -> Void) {
        queue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    /// Shows the log in Finder, creating an empty one if needed.
    func revealLogFile() {
        queue.async { [fileURL] in
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: fileURL)
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }

    // MARK: - The watch (all on `queue`)

    private struct Watch {
        let element: AXUIElement
        let appElement: AXUIElement
        let pid: pid_t
        let bundleID: String
        let appName: String
        let role: String?
        let subrole: String?
        let manualAccessibility: Bool
        let chromiumMarker: String?
        let manualAccessibilityResult: AXError?
        let focusAttempts: Int
        let generation: Int
        let deadline: Date
        var tracker: ReadbackTracker
    }

    private func currentGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    private struct Start {
        let text: String
        let stamp: String
        let appElement: AXUIElement
        let pid: pid_t
        let bundleID: String
        let appName: String
        let chromiumMarker: String?
        let generation: Int
    }

    private func begin(text: String, pid: pid_t, bundleID: String, bundleURL: URL?, appName: String, generation mine: Int) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        let cacheKey = bundleURL?.path ?? bundleID
        let marker: String?
        if let known = chromiumMarkerByBundle[cacheKey] {
            marker = known.isEmpty ? nil : known
        } else {
            marker = ChromiumAppDetection.marker(bundleURL: bundleURL, bundleID: bundleID)
            chromiumMarkerByBundle[cacheKey] = marker ?? ""
        }

        let start = Start(text: text, stamp: stamp, appElement: appElement, pid: pid, bundleID: bundleID,
                          appName: appName, chromiumMarker: marker, generation: mine)
        switchOnAccessibility(start)
        lookForFocus(start, attempt: 1)
    }

    /// Electron keeps its accessibility tree off until asked. Most apps are
    /// asked once per app run (those that do not support it answer
    /// unsupported). Electron/Chromium apps are asked again on every dictation
    /// and every focus retry until they accept: a busy app can time out, and a
    /// refusal must not be remembered for the rest of the run.
    private func switchOnAccessibility(_ start: Start) {
        if let known = manualAccessibilityByProcess[start.pid],
           known == .success || start.chromiumMarker == nil {
            return
        }
        let result = AXUIElementSetAttributeValue(
            start.appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        manualAccessibilityByProcess[start.pid] = result
        if manualAccessibilityByProcess.count > 64 {
            manualAccessibilityByProcess = manualAccessibilityByProcess.filter {
                NSRunningApplication(processIdentifier: $0.key) != nil
            }
        }
    }

    private func lookForFocus(_ start: Start, attempt: Int) {
        let manualResult = manualAccessibilityByProcess[start.pid]
        let manual = manualResult == .success

        func early(role: String?, subrole: String?, secure: Bool, endReason: String, error: String?) {
            var tracker = ReadbackTracker(inserted: start.text)
            tracker.observe(.timedOut)
            var record = tracker.record(timestamp: start.stamp, bundleID: start.bundleID, appName: start.appName,
                                        role: role, subrole: subrole, manualAccessibilityUsed: manual)
            record.secure = secure
            record.endReason = endReason
            record.error = error
            record.finalCaptured = false
            annotate(&record, start: start, attempts: attempt)
            append(record)
        }

        // Still missing, or not a text box yet: Electron often exposes focus a
        // beat late. Look again shortly, unless a new dictation took over.
        func retryOr(_ giveUp: () -> Void) {
            guard attempt < Self.focusAttempts, currentGeneration() == start.generation else {
                giveUp()
                return
            }
            queue.asyncAfter(deadline: .now() + Self.focusRetryInterval) { [self] in
                switchOnAccessibility(start)
                lookForFocus(start, attempt: attempt + 1)
            }
        }

        guard let element = focusedElement(of: start.appElement) else {
            retryOr {
                early(role: nil, subrole: nil, secure: false, endReason: "unreadable", error: "no focused element")
            }
            return
        }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)

        // A password field: nothing is read, not even once.
        if role == Self.secureRole || subrole == Self.secureRole {
            logger.notice("READBACK \(start.appName, privacy: .public): secure field, not read")
            early(role: role, subrole: subrole, secure: true, endReason: "secure", error: nil)
            return
        }
        guard let role, Self.textEntryRoles.contains(role) else {
            retryOr {
                early(role: role, subrole: subrole, secure: false, endReason: "notATextBox",
                      error: "focused element is \(role ?? "unknown"), not a text box")
            }
            return
        }

        let watch = Watch(
            element: element, appElement: start.appElement, pid: start.pid, bundleID: start.bundleID,
            appName: start.appName, role: role, subrole: subrole, manualAccessibility: manual,
            chromiumMarker: start.chromiumMarker, manualAccessibilityResult: manualResult,
            focusAttempts: attempt, generation: start.generation,
            deadline: Date().addingTimeInterval(Self.watchDuration),
            tracker: ReadbackTracker(inserted: start.text)
        )
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in
            poll(watch, stamp: start.stamp)
        }
    }

    /// The Part A diagnostics: which marker made the app count as Chromium,
    /// what it answered to the switch, and how many focus lookups it took.
    private func annotate(_ record: inout ReadbackRecord, start: Start, attempts: Int) {
        record.chromiumMarker = start.chromiumMarker
        record.manualAccessibilityResult = manualAccessibilityByProcess[start.pid].map(Self.describe)
        record.focusAttempts = attempts
    }

    private func poll(_ current: Watch, stamp: String) {
        var watch = current
        let keepGoing: Bool
        if currentGeneration() != watch.generation {
            keepGoing = watch.tracker.observe(.newDictation)
        } else if Date() >= watch.deadline {
            keepGoing = watch.tracker.observe(.timedOut)
        } else {
            // The value first, so a box that empties as focus moves (a click
            // on Send) still counts as cleared.
            if watch.tracker.observe(readValue(of: watch.element)) {
                if let focused = focusedElement(of: watch.appElement), CFEqual(focused, watch.element) {
                    keepGoing = true
                } else {
                    keepGoing = watch.tracker.observe(.focusLeft)
                }
            } else {
                keepGoing = false
            }
        }

        guard !keepGoing else {
            queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in
                poll(watch, stamp: stamp)
            }
            return
        }

        var record = watch.tracker.record(
            timestamp: stamp, bundleID: watch.bundleID, appName: watch.appName, role: watch.role,
            subrole: watch.subrole, manualAccessibilityUsed: watch.manualAccessibility)
        record.chromiumMarker = watch.chromiumMarker
        record.manualAccessibilityResult = watch.manualAccessibilityResult.map(Self.describe)
        record.focusAttempts = watch.focusAttempts
        // Phase 2b: small word swaps in the captured text are counted toward
        // suggested fixes. Only word pairs are kept (suggestion-candidates.json,
        // this edition's own folder), in both editions.
        if record.finalCaptured, let final = watch.tracker.lastNonEmpty {
            WordFixCandidateStore.shared.mineInBackground(
                inserted: watch.tracker.inserted, landed: watch.tracker.landed, final: final,
                otherTextInBox: record.otherTextInBox, app: watch.appName)
        }
        #if !BETA
        // Personal only: the owner's own words, the same data corpus.jsonl holds.
        record.insertedText = watch.tracker.inserted
        if let final = watch.tracker.lastNonEmpty, final.count <= Self.maximumStoredCharacters {
            record.finalText = final
        }
        #endif
        logger.notice(
            "READBACK \(watch.appName, privacy: .public): readable=\(record.readable, privacy: .public) captured=\(record.finalCaptured, privacy: .public) edited=\(record.edited, privacy: .public) end=\(record.endReason, privacy: .public)"
        )
        append(record)
    }

    private func readValue(of element: AXUIElement) -> ReadbackObservation {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if result == .success, let text = value as? String {
            return .value(text)
        }
        // No text — but does it still answer with a selection or a length?
        var range: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
        var count: CFTypeRef?
        let countResult = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
        let message = result == .success ? "value is not text" : "value: \(Self.describe(result))"
        return .valueUnavailable(rangeAvailable: rangeResult == .success || countResult == .success, error: message)
    }

    private func focusedElement(of appElement: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        case .apiDisabled: return "apiDisabled"
        default: return "error \(error.rawValue)"
        }
    }

    private func append(_ record: ReadbackRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("Could not write the read-back log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
