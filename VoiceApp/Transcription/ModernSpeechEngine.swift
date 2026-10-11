import AVFoundation
import Foundation
import OSLog
import Speech

/// Apple's macOS 26 speech engine — SpeechAnalyzer/SpeechTranscriber, the
/// successor to SFSpeechRecognizer this app was built on.
///
/// Independent benchmarks measure it at 3.5–4× fewer word errors than the old
/// engine (9.0%→2.1% clean, 16.3%→4.6% noisy) and about three times faster,
/// entirely on-device. For a voice the old engine mishears constantly, this is
/// the largest accuracy lever the app has ever had.
///
/// What it does NOT have: contextualStrings. The corpus vocabulary hints stay
/// wired to the classic engine, and the dictation-side replacement is
/// corpus-mined substitution rules in the cleaner — a follow-up.
///
/// The classic path remains fully intact. Any failure here — missing assets,
/// unsupported locale, analyzer error — reports, and the controller falls back
/// to the old engine for the rest of the session.
@available(macOS 26.0, *)
@MainActor
final class ModernSpeechEngine {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "ModernSpeech")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?

    /// Written on the main actor at start, read from the audio tap's thread by
    /// feed(). The first version reached it through MainActor.assumeIsolated —
    /// which is an assertion, and the tap thread failed it on the very first
    /// buffer, killing the whole app two seconds into a recording.
    private nonisolated(unsafe) var feeder: BufferFeeder?

    private var finalizedText = ""
    private var volatileText = ""
    private var finished = false

    /// Full live transcript (finalized plus volatile), on the main actor.
    var onTranscript: ((String) -> Void)?
    /// The definitive transcript, after the stream is finished and the
    /// analyzer has finalized everything.
    var onFinished: ((String) -> Void)?

    /// Downloads the model assets if the system hasn't already. Called once at
    /// launch so the first dictation never stalls behind a download.
    static func preflight() {
        Task {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "ModernSpeech")
            guard let locale = await Self.matchedLocale() else {
                logger.notice("New engine preflight: no supported locale")
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    logger.notice("New engine preflight: downloading model assets…")
                    try await request.downloadAndInstall()
                    logger.notice("New engine preflight: assets installed")
                } else {
                    logger.notice("New engine preflight: assets already present")
                }
            } catch {
                logger.error("New engine preflight failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The locale and asset check answered once per process. Asking the
    /// speech service on every Fn press cost 100ms when it was fresh and
    /// 650–865ms after three hours (2026-10-02); the answer never changes
    /// while the app runs.
    private static var readyLocale: Locale?

    private static func matchedLocale() async -> Locale? {
        if let readyLocale { return readyLocale }
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let exact = supported.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return exact
        }
        let language = current.language.languageCode?.identifier ?? "en"
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    /// Builds the analyzer and starts consuming. Throws when anything about
    /// the new engine is unavailable; the caller falls back to classic.
    func start(microphoneFormat: AVAudioFormat) async throws {
        guard let locale = await Self.matchedLocale() else {
            throw ModernSpeechError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if Self.readyLocale == nil {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                // Assets missing at dictation time (preflight should have caught
                // this). Install rather than fail — first run may pause here once.
                try await request.downloadAndInstall()
            }
            Self.readyLocale = locale
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        self.analyzer = analyzer
        self.transcriber = transcriber
        self.feeder = BufferFeeder(
            continuation: continuation,
            sourceFormat: microphoneFormat,
            targetFormat: analyzerFormat
        )

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    self.onTranscript?(self.currentText)
                }
                self?.deliverFinished()
            } catch {
                self?.logger.error("New engine results stream failed: \(error.localizedDescription, privacy: .public)")
                self?.deliverFinished()
            }
        }
    }

    /// Feed one microphone buffer. Safe from the audio tap's thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        feeder?.feed(buffer)
    }

    private var currentText: String {
        let joined = finalizedText + (volatileText.isEmpty ? "" : volatileText)
        return joined.trimmingCharacters(in: .whitespaces)
    }

    /// The recording ended: close the stream and let the analyzer finalize.
    ///
    /// Finishing is delivered by the RESULTS LOOP ending, never from here.
    /// The first version called deliverFinished the moment finalize returned —
    /// but finalized segments arrive through the results stream, which was
    /// often still mid-flight, so the "final" text was whatever had happened
    /// to land: short messages survived, long ones lost their tails or most
    /// of their body. Read the answer only after the mail stops coming.
    func finishStream() {
        feeder?.close()
        Task { @MainActor [weak self] in
            do {
                try await self?.analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                self?.logger.error("New engine finalize failed: \(error.localizedDescription, privacy: .public)")
                // The stream may never terminate after a failed finalize; this
                // is the one case where delivering from here is right.
                self?.deliverFinished()
            }
        }
    }

    private func deliverFinished() {
        guard !finished else { return }
        finished = true
        onFinished?(currentText)
    }

    func cancel() {
        feeder?.close()
        resultsTask?.cancel()
        resultsTask = nil
        // Dropping the reference left the session open in the speech
        // service; end it explicitly so nothing accumulates there.
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        feeder = nil
        onTranscript = nil
        onFinished = nil
    }
}

@available(macOS 26.0, *)
enum ModernSpeechError: LocalizedError {
    case localeUnsupported

    var errorDescription: String? {
        "The new speech engine does not support this language yet."
    }
}

/// Converts tap buffers to the analyzer's preferred format and yields them
/// into the analyzer's input stream. Lives on the audio tap's thread; the tap
/// delivers serially, so no locking beyond the close flag.
@available(macOS 26.0, *)
private final class BufferFeeder: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat?
    private let closed = NSLock()
    private var isClosed = false

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat?) {
        self.continuation = continuation
        self.targetFormat = targetFormat
        if let targetFormat, targetFormat != sourceFormat {
            self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        } else {
            self.converter = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        closed.lock()
        let stop = isClosed
        closed.unlock()
        guard !stop else { return }

        guard let converter, let targetFormat else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func close() {
        closed.lock()
        let alreadyClosed = isClosed
        isClosed = true
        closed.unlock()
        guard !alreadyClosed else { return }
        continuation.finish()
    }
}
