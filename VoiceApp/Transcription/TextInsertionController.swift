import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

enum TextInsertionError: LocalizedError {
    case permissionRequired
    case noTargetApplication
    case secureInputActive
    case destinationNotRunning
    case couldNotActivate(String)
    case insertionFailed
    /// A send arrived while one was still running. Distinct from a real failure so
    /// the review card can stay quiet instead of reporting that a send which is
    /// about to succeed has failed.
    case alreadySending
    /// The destination said it has no text field focused. Caught before pasting
    /// rather than discovered afterwards by the text not being there.
    case noFocusedField(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Allow \(AppEdition.displayName) under System Settings › Privacy & Security › Accessibility, then choose Use Text again."
        case .noTargetApplication:
            return "\(AppEdition.displayName) could not find the application where you were typing."
        case .secureInputActive:
            return "The focused field is a secure text field, so macOS blocks inserted text."
        case .destinationNotRunning:
            return "That app is not running."
        case .couldNotActivate(let name):
            return "\(name) would not come to the front. Your text is on the clipboard — press ⌘V."
        case .insertionFailed:
            return "That application did not accept the inserted text."
        case .alreadySending:
            return "A send is already running."
        case .noFocusedField(let name):
            return "Click into \(name)'s text box, then send again. Your text is on the clipboard — ⌘V also works."
        }
    }
}

enum InsertionOutcome {
    case inserted
    case copiedToClipboard
    /// The destination had nowhere for the text to land yet, so it is being held
    /// and will go in by itself the moment a text field there takes the caret.
    case waitingForSomewhereToLand
}

@MainActor
final class TextInsertionController: ObservableObject {
    static let shared = TextInsertionController()

    @Published private(set) var crumbDeliveryID = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "Insertion")

    /// Non-nil while a send is holding its paste until the destination has a
    /// focused text field. The review card shows this, so "say send, then click
    /// the box" completes itself instead of failing and asking for a retry.
    @Published private(set) var awaitingFocusIn: String?

    private var isSending = false
    private var targetProcessIdentifier: pid_t?
    private var activationObserver: NSObjectProtocol?

    private init() {
        targetProcessIdentifier = Self.currentForegroundApplication()

        // Clicking the pill makes VoiceApp the frontmost app, so the target has to
        // be tracked continuously rather than sampled at the moment of recording.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.targetProcessIdentifier = application.processIdentifier
            }
        }
    }

    /// Diagnostic only: can this app find out whether a destination has a focused
    /// text field before pasting into it?
    ///
    /// The focused-element check was removed once already because it refused every
    /// real destination — Electron apps ship with their accessibility tree off, so
    /// the question came back empty for Claude and every browser. Electron
    /// documents `AXManualAccessibility` for assistive software to switch that tree
    /// on from outside. This measures whether that actually works here, because
    /// the whole idea rests on it.
    ///
    /// It asks two things and no more: does a focused element exist, and what is
    /// its role. Role is structural — "AXTextArea" — never content. Nothing is
    /// pasted and nothing is changed.
    func probeFocusVisibility(of bundleIdentifier: String) {
        guard AXIsProcessTrusted() else {
            logger.error("FOCUS PROBE: no Accessibility permission")
            return
        }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            logger.notice("FOCUS PROBE \(bundleIdentifier, privacy: .public): not running")
            return
        }

        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        let name = application.localizedName ?? bundleIdentifier

        let setResult = AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        logger.notice("FOCUS PROBE \(name, privacy: .public) set AXManualAccessibility: \(Self.describe(setResult), privacy: .public)")

        // The app has to be ACTIVE for the question to mean anything: an app in
        // the background has no focused element, and answering "noValue" there
        // says nothing about whether it would answer when it is in front. This
        // mirrors what a real send does — activate, then look.
        NSApp.deactivate()
        application.activate()
        Thread.sleep(forTimeInterval: 1.5)

        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        logger.notice(
            "FOCUS PROBE \(name, privacy: .public) frontmost=\(isFront, privacy: .public): \(Self.focusDescription(of: axApp), privacy: .public)"
        )

    }

    /// Roles that mean "typing would go somewhere". Measured against Claude: with
    /// the cursor in the message box the focused role is `AXTextArea`; with the
    /// window merely in front it is `AXWebArea`. That difference is what tells a
    /// paste that will land from one that will vanish.
    private static let textEntryRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    /// Asks the destination whether typing would currently land somewhere.
    ///
    /// Returns nil when the app will not say — which is not the same as "no". Apps
    /// that refuse the accessibility switch (Chrome answers `attributeUnsupported`)
    /// can never answer, and refusing to paste into them would break every send to
    /// a browser. A nil means "carry on blind, as before".
    private func focusedFieldIsReady(in application: NSRunningApplication) -> Bool? {
        let axApp = AXUIElementCreateApplication(application.processIdentifier)

        // The timeout is the whole difference between this check and the one that
        // had to be torn out. Every call below is synchronous and cross-process,
        // and without a timeout each one may block for the system default of six
        // seconds. In a polling loop on the main actor that is not a slow check,
        // it is a frozen app: the review card stopped responding to the user's
        // own clicks while it sat inside these calls waiting on a busy Electron
        // app. A quarter of a second is far longer than a healthy answer takes
        // and short enough that an unhealthy one costs nothing.
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        // Electron ships with its accessibility tree switched off, which is why the
        // original focused-element check refused every real destination and had to
        // be removed. This is the documented way for assistive software to ask for
        // it. Apps that do not support it return attributeUnsupported and are then
        // treated as unanswerable rather than as failing.
        let switched = AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focused)

        guard result == .success, let focused else {
            // An app that took the switch but has nothing focused is genuinely not
            // ready. One that never took it cannot be asked at all.
            return switched == .success ? false : nil
        }

        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        guard roleResult == .success, let role = role as? String else { return nil }

        return Self.textEntryRoles.contains(role)
    }

    private static func focusDescription(of axApp: AXUIElement) -> String {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else {
            return "no focused element (\(describe(result)))"
        }

        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        guard roleResult == .success, let role = role as? String else {
            return "focused element present, role unavailable (\(describe(roleResult)))"
        }
        return "focused element role = \(role)"
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notImplemented: return "notImplemented"
        case .noValue: return "noValue"
        case .apiDisabled: return "apiDisabled"
        default: return "other(\(error.rawValue))"
        }
    }

    func captureTargetApplication() {
        // Starting a new dictation supersedes any text still waiting to land, so
        // an old one cannot appear underneath a new one.
        cancelHold()
        // Ends any read-back watch still following the previous dictation.
        ReadbackProbe.shared.dictationStarted()
        guard let identifier = Self.currentForegroundApplication() else { return }
        targetProcessIdentifier = identifier
    }

    /// Copies reviewed text. The permission-free path, and what the review card's
    /// main button always does.
    func insert(_ text: String) -> Result<InsertionOutcome, TextInsertionError> {
        guard !text.isEmpty else { return .failure(.insertionFailed) }
        return copyToClipboard(text)
    }

    var canInsertIntoApps: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Inserts into an app the user named, rather than one VoiceApp guessed at.
    ///
    /// This deliberately uses the paste path rather than writing through
    /// Accessibility. Electron and Chromium apps — Claude and ChatGPT among them —
    /// accept an Accessibility write, report success, and display nothing, so the
    /// text vanished with no error. Activating the app and pasting works in every
    /// app tested, and brings the destination forward so the result is visible
    /// rather than taken on trust. The clipboard is borrowed and restored.
    func insert(_ text: String, into bundleIdentifier: String) async -> Result<InsertionOutcome, TextInsertionError> {
        logger.notice("Send requested to \(bundleIdentifier, privacy: .public) (\(text.count, privacy: .public) characters)")

        guard !text.isEmpty else {
            logger.error("Send refused: nothing to send")
            return .failure(.insertionFailed)
        }

        guard !isSending else {
            logger.error("Send refused: another send is still in flight")
            audit(method: "app", outcome: "refused — a send was already in flight", characters: text.count, destination: bundleIdentifier)
            return .failure(.alreadySending)
        }

        isSending = true
        defer { isSending = false }

        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            audit(method: "app", outcome: "blocked — no Accessibility permission", characters: text.count, destination: bundleIdentifier)
            return .failure(.permissionRequired)
        }

        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            audit(method: "app", outcome: "failed — app is not running", characters: text.count, destination: bundleIdentifier)
            return .failure(.destinationNotRunning)
        }

        let pid = application.processIdentifier
        targetProcessIdentifier = pid

        // A remote-desktop window is a picture of another computer. A synthetic
        // ⌘V aimed at it is forwarded to that machine, which pastes ITS clipboard
        // — not what was just dictated. Copy and say so instead of pretending.
        guard !Self.remoteDesktopApps.contains(bundleIdentifier) else {
            let name = application.localizedName ?? bundleIdentifier
            logger.notice("\(name, privacy: .public) is a remote screen; copying instead of pasting")
            audit(method: "clipboard", outcome: "copied — remote screen", characters: text.count, destination: bundleIdentifier)
            _ = copyToClipboard(text)
            application.activate()
            return .success(.copiedToClipboard)
        }

        guard !IsSecureEventInputEnabled() else {
            audit(method: "app", outcome: "blocked — secure input active", characters: text.count, destination: bundleIdentifier)
            return .failure(.secureInputActive)
        }

        return await insertUsingPaste(text, into: application, destination: bundleIdentifier)
    }

    /// Put the words where the caret already is, without touching focus.
    ///
    /// This is the entire difference between having a review card and not having
    /// one, and it is why this path has none of the other one's failure modes.
    /// Nothing is activated, nothing is deactivated, no window appears — so the
    /// caret never leaves the destination and there is nothing to hand back.
    ///
    /// Every delivery failure this app has had came from the same place: the card
    /// took focus, and the send then had to go find the destination, wake it, and
    /// interrogate it about whether its text box was ready. That whole apparatus
    /// is unreachable from here. There is no app to raise, so it cannot fail to
    /// come forward; no focus to restore, so it cannot fail to settle.
    ///
    /// The one requirement it trades for all that: the caret must already be
    /// where the words should go, which it is, because the user put it there
    /// before they started talking.
    func insertAtCursor(_ text: String) async -> Result<InsertionOutcome, TextInsertionError> {
        guard !text.isEmpty else { return .failure(.insertionFailed) }

        guard !isSending else {
            logger.error("Insert refused: another insert is still in flight")
            return .failure(.alreadySending)
        }
        isSending = true
        defer { isSending = false }

        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            audit(method: "cursor", outcome: "blocked — no Accessibility permission", characters: text.count)
            return .failure(.permissionRequired)
        }

        // Normally the destination is simply whatever is in front, because this
        // app never came forward. It is only not in front when the recording was
        // started by clicking the orb, which does make VoiceApp active — so fall
        // back to the app that was frontmost when recording began.
        var destination = NSWorkspace.shared.frontmostApplication
        let isSelf = destination?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if isSelf {
            guard let pid = targetProcessIdentifier,
                  let remembered = NSRunningApplication(processIdentifier: pid) else {
                audit(method: "cursor", outcome: "failed — no destination", characters: text.count)
                return .failure(.noTargetApplication)
            }
            destination = remembered
            remembered.activate()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(50))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            }
            // Raised from behind, its own caret needs a moment to come back.
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard let application = destination else {
            audit(method: "cursor", outcome: "failed — no destination", characters: text.count)
            return .failure(.noTargetApplication)
        }
        let name = application.localizedName ?? "the frontmost app"
        let identifier = application.bundleIdentifier ?? name

        // A remote-desktop window is a picture of another computer; a synthetic
        // ⌘V aimed at it pastes THAT machine's clipboard. Copy and stop.
        if Self.remoteDesktopApps.contains(identifier) {
            audit(method: "clipboard", outcome: "copied — remote screen", characters: text.count, destination: identifier)
            return copyToClipboard(text)
        }

        guard !IsSecureEventInputEnabled() else {
            audit(method: "cursor", outcome: "blocked — secure input active", characters: text.count, destination: identifier)
            return .failure(.secureInputActive)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            audit(method: "cursor", outcome: "failed — clipboard unavailable", characters: text.count, destination: identifier)
            return .failure(.insertionFailed)
        }

        // Is there anywhere for this to land? A ⌘V posted at a window whose caret
        // is not in a text field vanishes and nothing reports it — which is how a
        // dictation ends up somewhere its author cannot find. Apps that will not
        // answer (Chrome returns attributeUnsupported) come back nil and are
        // pasted into blind, exactly as before, so nothing that worked stops
        // working.
        if focusedFieldIsReady(in: application) == false {
            logger.notice("Nothing in \(name, privacy: .public) can take text yet; holding it")
            audit(method: "cursor", outcome: "held — nothing focused yet", characters: text.count, destination: identifier)
            holdUntilSomewhereToLand(in: application, text: text, destination: identifier)
            return .success(.waitingForSomewhereToLand)
        }

        guard postPaste() else {
            audit(method: "cursor", outcome: "failed — could not create keystroke", characters: text.count, destination: identifier)
            return .failure(.insertionFailed)
        }

        logger.notice("Pasted \(text.count, privacy: .public) characters at the caret in \(name, privacy: .public)")
        audit(method: "cursor", outcome: "pasted", characters: text.count, destination: identifier)
        crumbDeliveryID += 1
        ReadbackProbe.shared.watch(inserted: text, in: application)
        return .success(.inserted)
    }

    /// True while a finished dictation is waiting for somewhere to go. The orb
    /// shows this — there is nothing to click and nothing takes focus, because
    /// anything that did would be the very problem this exists to avoid.
    @Published private(set) var isHoldingText = false

    private var holdTask: Task<Void, Never>?

    /// Wait for the destination to have a text field with the caret in it, then
    /// paste. This is the old "waiting for a click" idea with the two things that
    /// made it a disaster removed: the AX calls can no longer block (see the
    /// timeout in `focusedFieldIsReady`), and it no longer holds up anything the
    /// user might do in the meantime.
    ///
    /// Bounded to the app the words were meant for. Following the caret into
    /// whatever the user opened next would mean a dictation appearing in a search
    /// box thirty seconds later, which is worse than not arriving.
    private func holdUntilSomewhereToLand(
        in application: NSRunningApplication,
        text: String,
        destination: String
    ) {
        let characters = text.count
        holdTask?.cancel()
        isHoldingText = true

        holdTask = Task { @MainActor [weak self] in
            defer { self?.isHoldingText = false }

            for _ in 0..<120 {                       // 120 × 250ms = 30 seconds
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }

                // Switching to another app is changing your mind. The text stays
                // on the clipboard, where ⌘V still reaches it.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == application.processIdentifier else {
                    self.logger.notice("Stopped holding — another app came forward")
                    return
                }

                guard self.focusedFieldIsReady(in: application) == true else { continue }
                guard self.postPaste() else { return }

                let name = application.localizedName ?? destination
                self.crumbDeliveryID += 1
                self.logger.notice("Held text landed in \(name, privacy: .public)")
                self.audit(method: "cursor", outcome: "pasted after waiting for a text field",
                           characters: characters, destination: destination)
                ReadbackProbe.shared.watch(inserted: text, in: application)
                return
            }

            self?.logger.notice("Nothing took the caret within 30s; the text is still on the clipboard")
        }
    }

    /// A new dictation supersedes anything still waiting.
    func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        isHoldingText = false
    }

    /// A real ⌘V begins with the Command key going down on its own. Apps that
    /// track modifier state from those events — Chromium and Electron do — can
    /// disregard a V that carries a command flag they never saw pressed.
    ///
    /// A private source, NOT `.combinedSessionState`: the combined state merges
    /// live hardware modifiers, and this app is driven by holding Fn, so a ⌘V
    /// fired moments after release could go out as fn+⌘V and be ignored.
    private func postPaste() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else {
            return false
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        usleep(20_000)
        vDown.post(tap: .cghidEventTap)
        usleep(30_000)
        vUp.post(tap: .cghidEventTap)
        usleep(20_000)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    /// The no-permission path: VoiceApp writes to its own clipboard and stops
    /// there. Nothing reaches another application until the user pastes.
    private func copyToClipboard(_ text: String) -> Result<InsertionOutcome, TextInsertionError> {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            audit(method: "clipboard", outcome: "failed", characters: text.count)
            return .failure(.insertionFailed)
        }

        audit(method: "clipboard", outcome: "copied", characters: text.count)
        return .success(.copiedToClipboard)
    }

    private func audit(method: String, outcome: String, characters: Int, destination explicit: String? = nil) {
        let destination: String
        if let explicit {
            destination = explicit
        } else if method == "clipboard" {
            destination = "(clipboard)"
        } else if let targetProcessIdentifier,
                  let application = NSRunningApplication(processIdentifier: targetProcessIdentifier) {
            destination = application.bundleIdentifier ?? application.localizedName ?? "unknown"
        } else {
            destination = "unknown"
        }

        InsertionAuditLog.shared.record(
            method: method,
            destination: destination,
            characters: characters,
            outcome: outcome
        )
    }

    /// Windows that are pictures of another computer rather than somewhere text can land.
    private static let remoteDesktopApps: Set<String> = [
        "com.apple.ScreenSharing",
        "com.teamviewer.TeamViewer",
        "com.anydesk.anydesk",
        "com.parsecgaming.parsec",
        "com.p5sys.jump.mac.viewer",
        "com.edovia.screensharing",
        "com.microsoft.rdc.macos",
        "com.google.chromeremotedesktop",
        "com.realvnc.vncviewer",
        "com.nulana.remotixmac",
    ]

    private static func currentForegroundApplication() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return application.processIdentifier
    }

    /// Pastes into an app, and only reports success once the keystroke has actually
    /// been delivered to it.
    ///
    /// The previous version fired the keystroke 120ms after asking the app to
    /// activate and returned success regardless. When the app was slower than that
    /// — Electron apps routinely are — the paste went to whatever was still in
    /// front, and the user was told the text had been sent somewhere it had not.
    private func insertUsingPaste(
        _ text: String,
        into application: NSRunningApplication,
        destination: String
    ) async -> Result<InsertionOutcome, TextInsertionError> {
        let name = application.localizedName ?? destination

        // A private source, NOT .combinedSessionState. The combined state merges the
        // live hardware modifiers into whatever is posted — and this app is driven
        // by holding Fn, so a synthetic ⌘V fired moments after release could go out
        // as fn+⌘V and be ignored. That alone would make it land some times and not
        // others.
        guard let source = CGEventSource(stateID: .privateState) else {
            audit(method: "paste", outcome: "failed — no event source", characters: text.count, destination: destination)
            return .failure(.insertionFailed)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            audit(method: "paste", outcome: "failed — clipboard unavailable", characters: text.count, destination: destination)
            return .failure(.insertionFailed)
        }

        // Clicking a destination pill makes VoiceApp the active app, so activation
        // has to be handed back before the target can accept a keystroke.
        //
        // Whether the app was ALREADY in front decides how long it needs after
        // that. An app being raised from the background has to restore focus to
        // its own text field, and in Chromium and Electron apps that happens on a
        // later turn of their event loop than the window becoming key. This is the
        // "first send does nothing, second send works" case: the first paste is
        // posted to a window whose input is not focused yet and vanishes, and by
        // the second the field is already focused and it lands.
        let wasAlreadyFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier

        NSApp.deactivate()
        application.activate()

        var isFrontmost = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(50))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                isFrontmost = true
                break
            }
        }

        guard isFrontmost else {
            let actual = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
            logger.error(
                "\(name, privacy: .public) never came to the front (\(actual, privacy: .public) still is); leaving the text on the clipboard"
            )
            audit(
                method: "paste",
                outcome: "failed — app never came to the front; text left on clipboard",
                characters: text.count,
                destination: destination
            )
            // The transcript deliberately stays on the clipboard so ⌘V still works.
            return .failure(.couldNotActivate(name))
        }

        // Wait until the app says a text field has focus, rather than guessing how
        // long that takes. The guess was the bug: 350ms was enough when the app was
        // already in front and not enough when it had just been raised, so the
        // first send after switching apps pasted into a window that was not ready
        // and vanished — while the log said it had been pasted.
        //
        // An app that cannot be asked falls back to the old fixed wait, so nothing
        // that worked before stops working.
        var focusConfirmed = false
        let settleDeadline = wasAlreadyFrontmost ? 8 : 24  // ×50ms → 400ms or 1.2s

        for attempt in 0..<settleDeadline {
            try? await Task.sleep(for: .milliseconds(50))
            switch focusedFieldIsReady(in: application) {
            case .some(true):
                focusConfirmed = true
            case .some(false):
                continue
            case nil:
                // Unanswerable. Serve out the old fixed wait and paste blind.
                let remaining = (wasAlreadyFrontmost ? 350 : 900) - (attempt + 1) * 50
                if remaining > 0 {
                    try? await Task.sleep(for: .milliseconds(remaining))
                }
                logger.notice("\(name, privacy: .public) cannot report focus; pasting unverified")
            }
            break
        }

        // The app answered "no field focused". Refusing here made the user redo
        // the whole command: the log showed a refusal at 20:33:20, the user
        // clicking into the box, and the same send being re-spoken nine seconds
        // later. So instead the send now waits — the card says where to click,
        // and the paste fires the moment the field reports focus. Waiting ends
        // early if the user fronts a different app, which reads as changing
        // their mind.
        if !focusConfirmed, focusedFieldIsReady(in: application) == false {
            logger.notice("\(name, privacy: .public) has no focused text field; waiting for a click")
            awaitingFocusIn = name
            defer { awaitingFocusIn = nil }

            let patienceMilliseconds = 12_000
            var waited = 0
            while waited < patienceMilliseconds {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 100

                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                    logger.notice("Stopped waiting on \(name, privacy: .public) — another app came to the front")
                    break
                }
                if focusedFieldIsReady(in: application) == true {
                    focusConfirmed = true
                    break
                }
            }
        }

        if focusConfirmed {
            logger.notice("\(name, privacy: .public) has a focused text field; pasting")
        } else if focusedFieldIsReady(in: application) == false {
            // It answered no for the whole wait. The text stays on the clipboard
            // and the card stays up, instead of a paste disappearing silently.
            logger.error("\(name, privacy: .public) has no focused text field; not pasting")
            audit(
                method: "paste",
                outcome: "failed — no text field focused; text left on clipboard",
                characters: text.count,
                destination: destination
            )
            return .failure(.noFocusedField(name))
        }

        // Focus can move during that wait — including back to VoiceApp's own pill,
        // which is a key-capable panel sitting above everything. Posting blindly
        // after the earlier check is how a paste disappears into nothing.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            let actual = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
            logger.error("Focus moved to \(actual, privacy: .public) before pasting into \(name, privacy: .public)")
            audit(
                method: "paste",
                outcome: "failed — focus moved away before pasting; text left on clipboard",
                characters: text.count,
                destination: destination
            )
            return .failure(.couldNotActivate(name))
        }

        // A real ⌘V begins with the Command key going down on its own. Apps that
        // track modifier state from those events — Chromium and Electron do —
        // can disregard a V that carries a command flag they never saw pressed.
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else {
            audit(method: "paste", outcome: "failed — could not create keystroke", characters: text.count, destination: destination)
            return .failure(.insertionFailed)
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        vDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(30))
        vUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        commandUp.post(tap: .cghidEventTap)

        logger.notice("Pasted \(text.count, privacy: .public) characters into \(name, privacy: .public)")
        audit(method: "paste", outcome: "pasted", characters: text.count, destination: destination)

        // The transcript stays on the clipboard on purpose. A synthetic ⌘V cannot
        // be verified — the app may ignore it, and Electron apps read the
        // pasteboard asynchronously, so restoring the previous contents could even
        // race the paste. Leaving it there costs nothing and means ⌘V always works
        // if the keystroke did not take.
        crumbDeliveryID += 1
        ReadbackProbe.shared.watch(inserted: text, in: application)
        return .success(.inserted)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
