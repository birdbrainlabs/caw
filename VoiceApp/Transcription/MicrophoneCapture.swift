import AVFoundation
import OSLog
import Speech

/// Microphone capture for speech recognition.
///
/// This follows the pattern Apple documents on `-[AVAudioNode
/// installTapOnBus:bufferSize:format:block:]`, whose header carries this exact
/// example for capturing from the input node:
///
///     AVAudioEngine *engine = [[AVAudioEngine alloc] init];
///     AVAudioInputNode *input = [engine inputNode];
///     AVAudioFormat *format = [input outputFormatForBus: 0];
///     [input installTapOnBus: 0 bufferSize: 8192 format: format block: ...];
///
/// The format always comes *from the node*. A hand-built format that disagrees
/// with the hardware — in channel count especially — produces an input that
/// starts without error and then never delivers a buffer.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "AudioCapture")

    /// Apple's recognizer finalizes itself after a pause, so a long dictation is
    /// made of several recognition requests. The microphone stays open across all
    /// of them and buffers are redirected to whichever request is current.
    private let requestLock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?

    private var isRunning = false
    private var framesAtLastLog: Int64 = 0
    private var intervalPeak: Float = 0

    /// Fires once when the speaker has clearly stopped talking. Used only where
    /// nothing else can end a recording — never while a key is held, because
    /// there the key is the signal and a thinking pause must not cut you off.
    var onSilence: (@Sendable () -> Void)?
    var silenceSeconds: Double = 2.5

    /// The live input level, so the orb can distort to an actual voice rather
    /// than a simulated one.
    var onLevel: (@Sendable (Float) -> Void)?

    /// Raw buffers, for the new speech engine (via `EarlyAudioBank`). Runs on
    /// the tap's thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private var silentFrames: Int64 = 0
    private var heardSpeech = false
    private var hasReportedSilence = false

    /// Measured from real recordings: speech runs 0.1–0.35, a quiet room 0.002–0.006.
    private static let speechLevel: Float = 0.05
    private static let silenceLevel: Float = 0.015

    /// Diagnostics, so a failed session can say whether the microphone sent
    /// nothing, sent silence, or sent audio the recognizer could not use.
    private(set) var capturedFrames: Int64 = 0
    private(set) var peakLevel: Float = 0

    /// The hardware format actually in use, for consumers (the new speech
    /// engine) that must match it rather than assume it.
    private(set) var currentFormat: AVAudioFormat?

    /// `request` may be nil for capture that feeds no recognizer — the
    /// new speech engine takes the buffers through `onBuffer` instead.
    func start(request: SFSpeechAudioBufferRecognitionRequest?) throws {
        stop()

        capturedFrames = 0
        peakLevel = 0
        framesAtLastLog = 0
        intervalPeak = 0
        silentFrames = 0
        heardSpeech = false
        hasReportedSilence = false
        setCurrentRequest(request)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Without microphone access the input node reports a zero format rather
        // than failing outright.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("Input node reported an unusable format — microphone access is most likely denied")
            throw MicrophoneCaptureError.inputUnavailable
        }

        currentFormat = format

        // AVAudioNode.h documents the supported bufferSize range as [100, 400] ms.
        let bufferSize = AVAudioFrameCount(format.sampleRate * 0.2)

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.activeRequest()?.append(buffer)
            self.onBuffer?(buffer)
            self.measure(buffer, sampleRate: format.sampleRate)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            logger.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        isRunning = true
        logger.notice(
            "Capture started — input format \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch, buffer \(bufferSize, privacy: .public) frames"
        )
    }

    /// Points the microphone at a new recognition request without interrupting
    /// capture, so a pause never costs the user a syllable.
    func redirect(to request: SFSpeechAudioBufferRecognitionRequest) {
        setCurrentRequest(request)
    }

    private func setCurrentRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock()
        currentRequest = request
        requestLock.unlock()
    }

    private func activeRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        requestLock.lock()
        defer { requestLock.unlock() }
        return currentRequest
    }

    func stop() {
        setCurrentRequest(nil)
        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if capturedFrames > 0 {
            logger.notice(
                "Capture stopped — \(self.capturedFrames, privacy: .public) frames, peak level \(self.peakLevel, privacy: .public)"
            )
        } else {
            logger.error("Capture stopped without ever receiving an input buffer")
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        let frameLength = Int(buffer.frameLength)
        capturedFrames += Int64(frameLength)

        if let channel = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for index in 0..<frameLength {
                peak = max(peak, abs(channel[index]))
            }
            intervalPeak = max(intervalPeak, peak)
            peakLevel = max(peakLevel, peak)
            onLevel?(peak)

            if peak > Self.speechLevel {
                heardSpeech = true
                silentFrames = 0
            } else if peak < Self.silenceLevel {
                silentFrames += Int64(frameLength)
            } else {
                silentFrames = 0
            }

            // Only after speech has actually been heard, so a quiet moment before
            // you start talking can never end the recording before it begins.
            if heardSpeech, !hasReportedSilence, onSilence != nil,
               Double(silentFrames) >= sampleRate * silenceSeconds {
                hasReportedSilence = true
                logger.notice("Silence for \(self.silenceSeconds, privacy: .public)s after speech")
                onSilence?()
            }
        }

        let framesPerSecond = Int64(sampleRate)
        guard framesPerSecond > 0, capturedFrames - framesAtLastLog >= framesPerSecond else { return }
        framesAtLastLog = capturedFrames
        logger.notice(
            "Capturing — \(self.capturedFrames, privacy: .public) frames, peak this second \(self.intervalPeak, privacy: .public)"
        )
        intervalPeak = 0
    }
}

/// Captures a few seconds and reports what arrived, without involving the UI or
/// the recognizer. Run with `--mic-test` to check the audio path on its own.
enum MicrophoneSelfTest {
    static func run(duration: TimeInterval = 3) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "MicTest")

        Task { @MainActor in
            var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                granted = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
                }
            }

            guard granted else {
                logger.error("MIC TEST — microphone permission is not granted")
                return
            }

            let capture = MicrophoneCapture()
            do {
                try capture.start(request: SFSpeechAudioBufferRecognitionRequest())
            } catch {
                logger.error("MIC TEST — failed to start: \(error.localizedDescription, privacy: .public)")
                return
            }

            try? await Task.sleep(for: .seconds(duration))
            capture.stop()

            logger.notice(
                "MIC TEST RESULT — \(capture.capturedFrames, privacy: .public) frames captured, peak level \(capture.peakLevel, privacy: .public)"
            )
        }
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "No microphone input is available. Check Sound settings and microphone permission."
        }
    }
}
