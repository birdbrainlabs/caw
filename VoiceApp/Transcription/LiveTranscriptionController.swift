import AppKit
import AVFoundation
import Combine
import OSLog
import Speech

@MainActor
final class LiveTranscriptionController: ObservableObject {
    static let shared = LiveTranscriptionController()

    @Published private(set) var rawTranscript = ""
    @Published private(set) var statusText = LiveTranscriptionController.readyStatus
    @Published private(set) var statusKind = StatusKind.ready
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isPreparing = false

    /// Live microphone level, 0…1, for the orb.
    @Published private(set) var inputLevel: Float = 0

    var hasTranscript: Bool {
        !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioCapture: MicrophoneCapture?
    private var finishingTimeoutTask: Task<Void, Never>?
    private var maximumRecordingTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    private var holdIsActive = false
    private var sessionEndsOnSilence = false
    private var completedSegments: [String] = []
    private var currentSegment = ""
    private var utteranceStartTimestamp: TimeInterval = 0
    private var lastCapturePeak: Float = 0
    private var lastCaptureFrames: Int64 = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "Transcription")

    static let readyStatus = "Ready — hold Fn or click to talk"

    private static let silenceDefaultsKey = "EndsRecordingOnSilence"

    /// Off by default, and never applied to a held key. Holding Fn means the key
    /// decides when you are finished; pausing to think must not end the recording.
    @Published var endsOnSilence: Bool = UserDefaults.standard.bool(forKey: LiveTranscriptionController.silenceDefaultsKey) {
        didSet { UserDefaults.standard.set(endsOnSilence, forKey: Self.silenceDefaultsKey) }
    }

    /// A safety net against a recording that never gets stopped, not a limit on
    /// how long you may speak. Pauses no longer end a recording, so this needs to
    /// comfortably outlast someone thinking mid-sentence.
    static let maximumRecordingSeconds = 300

    /// Whether a message is routine, informational, or something that went wrong.
    /// Previously the pill guessed from the text, so every message wore a warning
    /// triangle — including successes.
    enum StatusKind {
        case ready
        case info
        case warning
    }

    private init() {}

    private(set) var targetsCrumbChat = false
    /// The first-run setup window's practice box (Phase 2c).
    private(set) var targetsSetup = false
    #if !BETA
    private(set) var targetsHome = false
    #endif

    func beginHold(fromKey: Bool = true) {
        if !isRecording {
            targetsCrumbChat = CrumbChatWindow.shared.isKey
            targetsSetup = SetupWindow.shared.isKey
            #if !BETA
            targetsHome = RoostController.shared.isKey
            #endif
        }
        sessionEndsOnSilence = !fromKey && endsOnSilence
        TextInsertionController.shared.captureTargetApplication()
        // Load the model now, while there are several seconds of speech to cover
        // it — but only when it will be used. This runs inside the Fn event
        // callback, and a stalled callback is what gets the tap disabled.
        if FloatingPillController.punctuatesAutomatically {
            TranscriptPolisher.shared.prewarm()
        }
        let permissionsWereReady = permissionsAreReady
        holdIsActive = true
        guard !isRecording else { return }

        Task {
            // Once everything is granted there is nothing to ask for, so recording
            // starts immediately instead of flashing a permissions message on
            // every single hold.
            guard permissionsWereReady else {
                isPreparing = true
                defer { isPreparing = false }

                guard await ensurePermissions() else { return }

                // Permission sheets swallow the matching mouse-up/Fn-up event, so
                // the interaction that grants access only performs setup;
                // recording requires a fresh hold.
                holdIsActive = false
                setStatus(Self.readyStatus, kind: .ready)
                return
            }

            guard holdIsActive else {
                setStatus(Self.readyStatus, kind: .ready)
                return
            }

            // The new engine first, when available and not switched off; any
            // failure falls back to classic for the rest of the session rather
            // than costing a single dictation.
            if #available(macOS 26.0, *), Self.usesModernEngine, !modernEngineFailed {
                do {
                    try await startModernRecording()
                    return
                } catch {
                    modernEngineFailed = true
                    logger.error("New engine failed to start (\(error.localizedDescription, privacy: .public)); using classic for this session")
                }
            }

            do {
                try startRecording()
            } catch {
                stopAudioCapture()
                recognitionTask?.cancel()
                recognitionTask = nil
                recognitionRequest = nil
                isProcessing = false
                setStatus("Could not start transcription: \(error.localizedDescription)", kind: .warning)
            }
        }
    }

    /// The user's engine choice: the macOS 26 engine unless switched to classic.
    static var usesModernEngine: Bool {
        !UserDefaults.standard.bool(forKey: "SpeechEngineClassic")
    }

    /// Set when the new engine fails, so it is not retried every recording.
    private var modernEngineFailed = false

    /// Which engine produced the current transcript. The new engine punctuates
    /// as it hears, so the cleaner's run-on breaker must stand down for its
    /// text — mined from the OLD engine's unpunctuated output, it was stacking
    /// periods on top of the new engine's own. The user deleted 15 of them by
    /// hand in 60 sends before saying so.
    private(set) var modernProducedTranscript = false

    /// The cleaner, configured for whichever engine heard the words.
    var configuredCleaner: TranscriptDisfluencyCleaner {
        var cleaner = TranscriptDisfluencyCleaner()
        cleaner.breaksRunOnSentences = !modernProducedTranscript
        cleaner.wordFixes = WordFixStore.shared.current
        return cleaner
    }
    private var modernEngine: Any?

    @available(macOS 26.0, *)
    private func startModernRecording() async throws {
        let startedAt = Date()

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        finishingTimeoutTask?.cancel()
        finishingTimeoutTask = nil
        maximumRecordingTask?.cancel()
        maximumRecordingTask = nil
        stopAudioCapture()
        (modernEngine as? ModernSpeechEngine)?.cancel()

        lastCaptureFrames = 0
        lastCapturePeak = 0
        completedSegments = []
        currentSegment = ""
        utteranceStartTimestamp = 0
        rawTranscript = ""

        // The capture must exist first, because the engine needs the REAL
        // microphone format — the oldest lesson in this project.
        let capture = MicrophoneCapture()
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.inputLevel = min(1, level * 3) }
        }
        if sessionEndsOnSilence {
            capture.onSilence = { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.logger.notice("Ending the recording after a silence")
                    self.holdIsActive = false
                    self.finishAudioCapture()
                }
            }
        }

        let engine = ModernSpeechEngine()
        engine.onTranscript = { [weak self] text in
            self?.rawTranscript = text
        }

        // The engine takes a few hundred milliseconds to start and the first
        // word is spoken during them. Bank the audio from the first buffer and
        // pour it in once the engine is ready.
        let earlyAudio = EarlyAudioBank()
        capture.onBuffer = { [earlyAudio] buffer in
            earlyAudio.feed(buffer)
        }

        try capture.start(request: nil)
        let format = capture.currentFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        do {
            try await engine.start(microphoneFormat: format)
        } catch {
            capture.stop()
            throw error
        }

        earlyAudio.attach(engine)

        audioCapture = capture
        modernEngine = engine
        modernProducedTranscript = true
        isRecording = true

        isProcessing = false
        setStatus("Listening", kind: .info)

        let setupMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.notice("Recording started in \(setupMilliseconds, privacy: .public)ms (new engine)")

        // Fn was released while the engine was starting. `endHold` could not
        // end a recording that did not exist yet, so end it here — otherwise
        // this session lives on with nobody to stop it and swallows the next
        // press. Whatever was banked still gets transcribed.
        guard holdIsActive else {
            logger.notice("Hold ended during startup; finishing with what was heard")
            finishAudioCapture()
            return
        }

        maximumRecordingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumRecordingSeconds))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.holdIsActive = false
            self.finishAudioCapture()
            self.setStatus("Recording stopped after 5 minutes — finishing transcript…", kind: .info)
        }
    }

    func endHold() {
        holdIsActive = false
        guard isRecording else { return }
        finishAudioCapture()
    }

    func requestPermissions() {
        Task {
            isPreparing = true
            defer { isPreparing = false }
            if await ensurePermissions() {
                setStatus(Self.readyStatus, kind: .ready)
            }
        }
    }

    func clearTranscript() {
        rawTranscript = ""
        if !isRecording && !isProcessing {
            setStatus(Self.readyStatus, kind: .ready)
        }
    }

    func cancel() {
        holdIsActive = false
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        finishingTimeoutTask?.cancel()
        finishingTimeoutTask = nil
        maximumRecordingTask?.cancel()
        maximumRecordingTask = nil
        isProcessing = false
        isPreparing = false
        setStatus(Self.readyStatus, kind: .ready)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func ensurePermissions() async -> Bool {
        setStatus("Requesting transcription permissions…", kind: .info)

        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }

        guard speechStatus == .authorized else {
            setStatus("Speech Recognition permission is required", kind: .warning)
            return false
        }

        var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            microphoneStatus = granted ? .authorized : .denied
        }

        guard microphoneStatus == .authorized else {
            setStatus("Microphone permission is required", kind: .warning)
            return false
        }

        guard let recognizer else {
            setStatus("Speech recognition is unavailable for the current language", kind: .warning)
            return false
        }

        guard recognizer.supportsOnDeviceRecognition else {
            setStatus("On-device recognition is unavailable for the current language", kind: .warning)
            return false
        }

        return true
    }

    private var permissionsAreReady: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && recognizer?.supportsOnDeviceRecognition == true
    }

    private func startRecording() throws {
        let startedAt = Date()
        guard let recognizer else { throw TranscriptionError.recognizerUnavailable }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        finishingTimeoutTask?.cancel()
        finishingTimeoutTask = nil
        maximumRecordingTask?.cancel()
        maximumRecordingTask = nil
        stopAudioCapture()

        // Reset diagnostics too, so a failure never reports the previous
        // session's frame count and peak level.
        lastCaptureFrames = 0
        lastCapturePeak = 0
        completedSegments = []
        currentSegment = ""
        utteranceStartTimestamp = 0
        rawTranscript = ""

        let request = makeRecognitionRequest()
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
            guard let request else { return }
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error, for: request)
            }
        }

        try startDeviceCapture(for: request)
        modernProducedTranscript = false

        isRecording = true
        isProcessing = false
        setStatus("Listening", kind: .info)

        let setupMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.notice("Recording started in \(setupMilliseconds, privacy: .public)ms")

        maximumRecordingTask = Task { @MainActor [weak self, weak request] in
            try? await Task.sleep(for: .seconds(Self.maximumRecordingSeconds))
            guard
                !Task.isCancelled,
                let self,
                let request,
                self.recognitionRequest === request,
                self.isRecording
            else {
                return
            }

            self.holdIsActive = false
            self.finishAudioCapture()
            self.setStatus("Recording stopped after 5 minutes — finishing transcript…", kind: .info)
        }
    }

    private func finishAudioCapture() {
        maximumRecordingTask?.cancel()
        maximumRecordingTask = nil
        isProcessing = true
        setStatus("Finishing transcript…", kind: .info)

        // Let the last buffers arrive before tearing the tap down, otherwise the
        // final word never reaches the recognizer.
        let capture = audioCapture
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            capture?.stop()
            guard let self else { return }
            if let capture {
                self.lastCapturePeak = capture.peakLevel
                self.lastCaptureFrames = capture.capturedFrames
            }
            self.audioCapture = nil
            self.recognitionRequest?.endAudio()

            // The new engine: close its stream and let it finalize. Its
            // finished callback completes the session; the 6s timeout below
            // still backstops a hang.
            if #available(macOS 26.0, *), let engine = self.modernEngine as? ModernSpeechEngine {
                engine.onFinished = { [weak self] text in
                    guard let self else { return }
                    // The finalized text is authoritative — unless it is
                    // SHORTER than what we watched arrive live, in which case
                    // something was lost in finalization and the live text is
                    // the truth. Words the user saw must never disappear.
                    if text.count >= self.rawTranscript.count {
                        self.rawTranscript = text
                    }
                    self.modernEngine = nil
                    self.completeRecognition(status: self.hasTranscript ? "Transcript ready" : self.noSpeechStatus)
                }
                engine.finishStream()
            }
        }
        isRecording = false

        if #available(macOS 26.0, *), modernEngine is ModernSpeechEngine {
            finishingTimeoutTask?.cancel()
            finishingTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self, self.modernEngine != nil else { return }
                self.logger.error("New engine never finished; completing with the live text")
                (self.modernEngine as? ModernSpeechEngine)?.cancel()
                self.modernEngine = nil
                self.completeRecognition(status: self.hasTranscript ? "Transcript ready" : self.noSpeechStatus)
            }
            return
        }

        guard let request = recognitionRequest else { return }
        finishingTimeoutTask?.cancel()
        finishingTimeoutTask = Task { @MainActor [weak self, weak request] in
            try? await Task.sleep(for: .seconds(6))
            guard
                !Task.isCancelled,
                let self,
                let request,
                self.recognitionRequest === request
            else {
                return
            }

            self.recognitionTask?.cancel()
            self.completeRecognition(status: self.hasTranscript ? "Transcript ready" : self.noSpeechStatus)
        }
    }

    private func stopAudioCapture() {
        inputLevel = 0
        if #available(macOS 26.0, *), let engine = modernEngine as? ModernSpeechEngine {
            engine.cancel()
            modernEngine = nil
        }
        if let audioCapture {
            lastCapturePeak = audioCapture.peakLevel
            lastCaptureFrames = audioCapture.capturedFrames
        }
        audioCapture?.stop()
        audioCapture = nil

        isRecording = false
    }

    /// "No speech detected" is the same message whether the mic sent nothing, sent
    /// silence, or sent speech the recognizer could not use — so say which it was.
    private var noSpeechStatus: String {
        if lastCaptureFrames == 0 {
            return "The microphone sent no audio — check Sound settings"
        }
        if lastCapturePeak < 0.005 {
            return "Only silence reached \(AppEdition.displayName) — check the input device"
        }
        return "Didn't catch that — try again"
    }

    private func startDeviceCapture(for request: SFSpeechAudioBufferRecognitionRequest) throws {
        let capture = MicrophoneCapture()

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.inputLevel = min(1, level * 3) }
        }

        if sessionEndsOnSilence {
            capture.onSilence = { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.logger.notice("Ending the recording after a silence")
                    self.holdIsActive = false
                    self.finishAudioCapture()
                }
            }
        }

        try capture.start(request: request)
        audioCapture = capture
    }

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        // Periods, question marks and commas from the recognizer itself. Off by
        // default, which is why transcripts arrived as one unbroken run of words.
        request.addsPunctuation = true

        // Proper nouns the recognizer has no reason to know — otherwise "Claude"
        // comes back as "cloud". Destination names, plus the vocabulary mined
        // from the corpus: words the user keeps typing that the recognizer
        // keeps missing ("Mak", "spear", "quantizer"). Every hand correction
        // he has ever made is a hint here. Both arrays are already resolved
        // and cached; nothing here may block, because it runs as a recording
        // is starting.
        let vocabulary = InsertionDestinations.shared.chosenNames + TrainingCorpus.shared.minedVocabulary
        if !vocabulary.isEmpty {
            request.contextualStrings = vocabulary
        }

        return request
    }

    /// Apple's recognizer decides on its own that an utterance is over once you
    /// pause, and reports `isFinal`. That is the end of a *segment*, not the end of
    /// the recording — only releasing Fn or clicking the orb ends that. The
    /// finished text is banked and a fresh request takes over while the microphone
    /// keeps running.
    private func continueAfterSegment() {
        guard let recognizer, let audioCapture else {
            completeRecognition(status: hasTranscript ? "Transcript ready" : noSpeechStatus)
            return
        }

        recognitionTask = nil

        let request = makeRecognitionRequest()
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
            guard let request else { return }
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error, for: request)
            }
        }

        currentSegment = ""
        utteranceStartTimestamp = 0
        audioCapture.redirect(to: request)
        logger.notice("Segment finalized; recording continues on a new request")
    }

    private func bankCurrentSegment() {
        let trimmed = currentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            completedSegments.append(trimmed)
        }
        currentSegment = ""
        updateTranscript()
    }

    private func updateTranscript() {
        rawTranscript = (completedSegments + [currentSegment])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        for request: SFSpeechAudioBufferRecognitionRequest
    ) {
        guard recognitionRequest === request else { return }

        if let result {
            let incoming = result.bestTranscription.formattedString
            let utteranceStart = result.bestTranscription.segments.first?.timestamp ?? 0

            // The recognizer keeps extending `formattedString` across a pause, so
            // the ordinary case is that the text simply grew and nothing needs
            // banking. Only when it *shrinks* sharply has it abandoned the earlier
            // text and begun a new utterance — bank that text before it is lost.
            // (Banking on a first-segment timestamp jump duplicated every sentence,
            // because the text carried on accumulating regardless.)
            let textCollapsed = !currentSegment.isEmpty && incoming.count * 2 < currentSegment.count

            if textCollapsed {
                logger.notice(
                    "Recognizer restarted its transcript at \(utteranceStart, privacy: .public)s; banking \(self.currentSegment.count, privacy: .public) characters"
                )
                bankCurrentSegment()
            }

            utteranceStartTimestamp = utteranceStart
            currentSegment = incoming
            updateTranscript()

            if result.isFinal {
                bankCurrentSegment()

                if isRecording {
                    continueAfterSegment()
                } else {
                    completeRecognition(status: hasTranscript ? "Transcript ready" : noSpeechStatus)
                }
                return
            }
        }

        if let error {
            let failure = error as NSError
            logger.error(
                """
                Recognition failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public) \
                \(failure.localizedDescription, privacy: .public) — \
                \(self.lastCaptureFrames, privacy: .public) frames captured, peak \(self.lastCapturePeak, privacy: .public)
                """
            )

            bankCurrentSegment()

            // A recognizer failure part-way through a hold must not throw away the
            // recording either — bank what exists and carry on listening.
            if isRecording {
                continueAfterSegment()
                return
            }

            // Partial results already delivered are still usable; the recognizer
            // routinely reports an error at the end of a perfectly good session.
            guard !hasTranscript else {
                completeRecognition(status: "Transcript ready")
                return
            }

            completeRecognition(status: Self.isNoSpeechError(failure) ? noSpeechStatus : failure.localizedDescription)
        }
    }

    private static func isNoSpeechError(_ error: NSError) -> Bool {
        // kAFAssistantErrorDomain 1110 is "no speech"; 203/216 are the recognizer
        // giving up on a session that carried nothing worth transcribing.
        [1110, 203, 216, 301].contains(error.code)
    }

    private func completeRecognition(status: String) {
        stopAudioCapture()
        recognitionTask = nil
        recognitionRequest = nil
        finishingTimeoutTask?.cancel()
        finishingTimeoutTask = nil
        maximumRecordingTask?.cancel()
        maximumRecordingTask = nil
        isProcessing = false
        setStatus(status, kind: status == "Transcript ready" ? .info : .warning)
    }

    /// Anything that is not a transcript is a message, and messages expire. Errors
    /// used to sit in the pill until the next successful recording, which turned a
    /// single failure into a loop the user had to click their way out of.
    private func setStatus(_ status: String, kind: StatusKind) {
        statusResetTask?.cancel()
        statusResetTask = nil
        statusText = status
        statusKind = kind

        guard status != "Transcript ready", !hasTranscript else { return }

        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, !self.isRecording, !self.isProcessing else { return }
            self.statusText = Self.readyStatus
            self.statusKind = .ready
            self.statusResetTask = nil
        }
    }

    /// Shown after reviewed text is delivered, so the pill can confirm what
    /// happened without pretending it was an error.
    func announce(_ message: String) {
        setStatus(message, kind: .info)
    }

    func dismissStatus() {
        statusResetTask?.cancel()
        statusResetTask = nil
        guard !isRecording, !isProcessing, !isPreparing else { return }
        statusText = Self.readyStatus
        statusKind = .ready
    }
}

private enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "The speech recognizer is unavailable."
        case .microphoneUnavailable:
            return "No microphone input is available."
        }
    }
}

/// Holds microphone buffers that arrive before the modern engine has started,
/// then replays them into it in order. Capped so a stuck start cannot hoard
/// memory. Feed comes from the tap thread; attach from the main actor.
@available(macOS 26.0, *)
final class EarlyAudioBank: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var engine: ModernSpeechEngine?
    private static let maximumPending = 60  // ~12 seconds of 200ms buffers

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let target = engine
        if target == nil, pending.count < Self.maximumPending {
            pending.append(buffer)
        }
        lock.unlock()
        target?.feed(buffer)
    }

    func attach(_ engine: ModernSpeechEngine) {
        lock.lock()
        let backlog = pending
        pending = []
        self.engine = engine
        lock.unlock()
        for buffer in backlog {
            engine.feed(buffer)
        }
    }
}
