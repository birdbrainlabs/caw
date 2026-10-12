import AVFoundation
import AppKit
import Speech
import SwiftUI

/// First-run setup for the Beta edition (Phase 2c). Opens by itself on a
/// tester's first launch, at launch when a permission it needs has gone
/// missing (showIfNeeded), and from Settings › Permissions. The Personal
/// edition never opens it: its owner granted everything long ago.
///
/// Six pages: welcome, the four permissions, the Globe key, a practice
/// dictation, the learning notice, done. Nothing here grants anything by
/// itself — each permission row asks macOS, or opens the System Settings page
/// where the tester ticks the box, and its check turns green on its own.
///
/// The learning notice is what switches learning on in Beta: its switch starts
/// ON, and the choice is saved when the tester moves past that page. A tester
/// who never reaches it keeps the Beta default, off.
@MainActor final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()
    static let completedKey = "SetupCompletedV1"

    private var window: NSWindow?
    private let model = SetupModel()

    /// Dictation made while this window is in front lands in its practice box
    /// instead of being pasted into whatever app was in front before it.
    var isKey: Bool { window?.isKeyWindow == true && NSApp.isActive }

    /// Opens on the first launch, and again whenever the microphone or Input
    /// Monitoring is missing: macOS ties permissions to the app's signature, so
    /// an update signed differently (or a reset) takes them away, and without
    /// Input Monitoring holding Fn does nothing and says nothing.
    static func showIfNeeded() {
        guard AppEdition.isBeta else { return }
        let missingPermission = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || !CGPreflightListenEventAccess()
        guard !UserDefaults.standard.bool(forKey: completedKey) || missingPermission else { return }
        shared.show()
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Set Up \(AppEdition.displayName)"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupView(model: model, finish: { [weak self] in self?.finish() }))
            window.center()
            self.window = window
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func receiveDictation(_ text: String) {
        model.receiveDictation(text)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

/// What the Fn/Globe key does on its own, from Keyboard settings. Anything
/// but "Do Nothing" fires when the key is let go — so every dictation would
/// also open the emoji picker, switch keyboards, or start Apple's dictation.
enum GlobeKeySetting: Equatable {
    case doNothing
    case changeInputSource
    case emojiAndSymbols
    case appleDictation
    /// Never set on this Mac, so it is still at macOS's default, which is not
    /// "Do Nothing".
    case systemDefault

    static var current: GlobeKeySetting {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int else {
            return .systemDefault
        }
        switch value {
        case 0: return .doNothing
        case 1: return .changeInputSource
        case 2: return .emojiAndSymbols
        case 3: return .appleDictation
        default: return .systemDefault
        }
    }

    /// What the Mac also does with Fn, in the owner's wording (Phase 2c copy).
    /// Nil when it's already "Do Nothing" — setup then skips the page.
    var problem: String? {
        switch self {
        case .doNothing:
            return nil
        case .emojiAndSymbols, .systemDefault:
            return "Your Mac may also use Fn to open the emoji picker. Let’s turn that off so it doesn’t appear every time you finish speaking."
        case .changeInputSource:
            return "Your Mac may also use Fn to switch keyboard languages. Let’s turn that off so it doesn’t happen every time you finish speaking."
        case .appleDictation:
            return "Your Mac may also use Fn to start Apple’s dictation. Let’s turn that off so it doesn’t start every time you finish speaking."
        }
    }
}

@MainActor final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, permissions, globeKey, tryIt, learning, done
    }

    enum Permission: Hashable {
        case microphone, speech, inputMonitoring, accessibility
    }

    @Published var step: Step = .welcome
    @Published private(set) var granted: Set<Permission> = []
    /// Permissions macOS has already been asked for this session. The next
    /// click on that row opens System Settings instead, because macOS shows
    /// its own prompt only once.
    @Published private(set) var asked: Set<Permission> = []
    /// Read in `refresh()`, never at init: `SetupWindow.shared` is first touched
    /// inside the Fn callback, which must not wait on preferences.
    @Published private(set) var globeKey = GlobeKeySetting.doNothing
    @Published private(set) var practiceText = ""
    @Published var learnFromFixes = true

    private var timer: Timer?

    func start() {
        step = .welcome
        learnFromFixes = UserDefaults.standard.object(forKey: ReadbackProbe.enabledKey) as? Bool ?? true
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads every permission and the Globe key. Runs once a second while
    /// the window is open, so a box ticked in System Settings shows up here
    /// without the tester doing anything.
    func refresh() {
        var now: Set<Permission> = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        if SFSpeechRecognizer.authorizationStatus() == .authorized { now.insert(.speech) }
        if CGPreflightListenEventAccess() { now.insert(.inputMonitoring) }
        if TextInsertionController.shared.canInsertIntoApps { now.insert(.accessibility) }
        if now != granted { granted = now }

        // Input Monitoring ticked straight in System Settings, without the
        // button: start listening for Fn now rather than at the next launch.
        if now.contains(.inputMonitoring), !AppState.shared.isMonitoring {
            AppState.shared.retryMonitoring()
        }

        let key = GlobeKeySetting.current
        if key != globeKey { globeKey = key }
    }

    var allGranted: Bool { granted.count == 4 }

    func request(_ permission: Permission) {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            } else {
                openPrivacyPane("Privacy_Microphone")
            }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            } else {
                openPrivacyPane("Privacy_SpeechRecognition")
            }
        case .inputMonitoring:
            if asked.contains(.inputMonitoring) {
                openPrivacyPane("Privacy_ListenEvent")
            } else {
                // Asks macOS, and starts Fn listening the moment it's allowed.
                AppState.shared.requestPermissionAndRetry()
            }
        case .accessibility:
            if asked.contains(.accessibility) {
                openPrivacyPane("Privacy_Accessibility")
            } else {
                TextInsertionController.shared.requestAccessibilityPermission()
            }
        }
        asked.insert(permission)
        refresh()
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func receiveDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        practiceText = practiceText.isEmpty ? trimmed : practiceText + " " + trimmed
    }

    func clearPractice() {
        practiceText = ""
    }

    /// The pages this tester will see. The Fn page only appears when Fn
    /// needs fixing — or while it's on screen, so fixing it there doesn't
    /// make the page vanish from under them.
    var visibleSteps: [Step] {
        Step.allCases.filter { $0 != .globeKey || globeKey != .doNothing || step == .globeKey }
    }

    func goForward() {
        if step == .learning {
            UserDefaults.standard.set(learnFromFixes, forKey: ReadbackProbe.enabledKey)
        }
        let steps = visibleSteps
        if let index = steps.firstIndex(of: step), index + 1 < steps.count { step = steps[index + 1] }
    }

    func goBack() {
        let steps = visibleSteps
        if let index = steps.firstIndex(of: step), index > 0 { step = steps[index - 1] }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let finish: () -> Void

    /// The product name in prose. System Settings lists the full app name,
    /// so the line about it uses `AppEdition.displayName`.
    private var brand: String { AppEdition.brandName }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }

            Divider()

            HStack {
                if model.step != .welcome {
                    Button("Back") { model.goBack() }
                }
                Spacer()
                let steps = model.visibleSteps
                StepDots(current: steps.firstIndex(of: model.step) ?? 0, count: steps.count)
                Spacer()
                if model.step == .done {
                    Button("Start Using \(brand)") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.step == .welcome ? "Start" : "Continue") { model.goForward() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 580, height: 580)
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions: permissions
        case .globeKey: globeKey
        case .tryIt: tryIt
        case .learning: learning
        case .done: done
        }
    }

    private var permissionsMissing: some View {
        Label("A few permissions are still off. Go back to finish them.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pages (the owner's copy, 2026-09-28)

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your voice, wherever you’re typing")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold Fn. Talk. Let go.")
                .font(.title2)
            Paragraph("\(brand) takes it from there.")
            Paragraph("Nothing ever leaves your computer.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle("Set up \(brand)")
            Paragraph("\(brand) needs four permissions from macOS. You only have to do this once.")

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Microphone",
                    why: "Listen while you dictate.",
                    isGranted: model.granted.contains(.microphone),
                    buttonTitle: "Allow",
                    action: { model.request(.microphone) })
                PermissionRow(
                    title: "Speech Recognition",
                    why: "Turn your voice into text.",
                    isGranted: model.granted.contains(.speech),
                    buttonTitle: "Allow",
                    action: { model.request(.speech) })
                PermissionRow(
                    title: "Input Monitoring",
                    why: "Notice when Fn is pressed and released—nothing else.",
                    isGranted: model.granted.contains(.inputMonitoring),
                    buttonTitle: model.asked.contains(.inputMonitoring) ? "Open Settings" : "Allow",
                    action: { model.request(.inputMonitoring) })
                PermissionRow(
                    title: "Accessibility",
                    why: "Put the finished text at your cursor.",
                    isGranted: model.granted.contains(.accessibility),
                    buttonTitle: model.asked.contains(.accessibility) ? "Open Settings" : "Allow",
                    action: { model.request(.accessibility) })
            }

            Paragraph("Choose Allow for each permission. When System Settings opens, switch on \(AppEdition.displayName).")
            Paragraph("Completed steps will turn green.")
                .foregroundStyle(.secondary)
        }
    }

    private var globeKey: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle("Keep Fn free for dictation")
            if let problem = model.globeKey.problem {
                Paragraph(problem)
                Paragraph("Set **Press 🌐 key to** → **Do Nothing**.")
                Button("Open Keyboard Settings") { model.openKeyboardSettings() }
            } else {
                Label("Done.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle("Try \(brand)")
            Paragraph("Click below, hold Fn, and say something.")
            Paragraph("Release Fn when you’re done.")

            if !(model.granted.contains(.inputMonitoring) && model.granted.contains(.microphone) && model.granted.contains(.speech)) {
                permissionsMissing
            }

            ScrollView {
                Text(model.practiceText)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            if !model.practiceText.isEmpty {
                Label("That’s it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Paragraph("This test won’t be saved.")
                .foregroundStyle(.secondary)
        }
    }

    private var learning: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageTitle("Make \(brand) yours")
            Paragraph("\(brand) can learn the names, phrases, and unusual words you use every day.")
            Paragraph("Correct a mistake as you normally would. For the next 90 seconds, \(brand) notices changes to the text it just entered.")
            Paragraph("It remembers only the correction:")
            Text("“hear” → “here”")
                .font(.title3)
                .padding(.leading, 16)
            Paragraph("Never the sentence around it.")
            Paragraph("Correct the same word twice and \(brand) will ask if you’d like to remember it. It won’t make the change until you say yes.")
            Paragraph("Password fields are ignored. Your corrections never leave this Mac.")

            Toggle("Let \(brand) learn my corrections", isOn: $model.learnFromFixes)
                .toggleStyle(.checkbox)
                .padding(.vertical, 4)

            DictationLogNote(brand: brand)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle("Ready when you are")
            Paragraph("From now on, just put your cursor where you want the words to go:")
            Text("Hold Fn. Speak. Let go.")
                .font(.title2)
            if !model.allGranted {
                permissionsMissing
            }
            Paragraph("You’ll find \(brand) and its settings under the waveform icon in your menu bar.")
        }
    }
}

// MARK: Pieces

private struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title.bold())
    }
}

private struct Paragraph: View {
    let text: LocalizedStringKey
    init(_ text: String) { self.text = LocalizedStringKey(text) }
    var body: some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct PermissionRow: View {
    let title: String
    let why: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isGranted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button(buttonTitle, action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// The dictation log also keeps words, separately from learning, so the
/// learning page says so too.
private struct DictationLogNote: View {
    let brand: String
    @ObservedObject private var corpus = TrainingCorpus.shared

    var body: some View {
        if corpus.isEnabled {
            let howLong = corpus.retentionDays == 0 ? "until you delete it" : "for \(corpus.retentionDays) days"
            Text("\(brand) also keeps a local dictation history \(howLong), so it can pick up words you use often. You can change or disable this in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

