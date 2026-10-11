import AVFoundation
import Foundation
import OSLog

/// Caw's personality: a small library of authored lines, chosen by real events.
///
/// Deliberately not a language model. The polisher taught this project that the
/// on-device model invents; a familiar that occasionally says something weird
/// stops being a familiar. Every line here was written by a person, is keyed to
/// something that actually happened, and never asks the user for anything —
/// the roost has no streaks, no goals, no guilt. Indifference is part of the
/// character: a crow acknowledges you; it does not need you.
///
/// Lines may contain "{name}", replaced with whatever the user asked to be
/// called. No name set, no name used.
@MainActor
final class CawVoice: ObservableObject {
    static let shared = CawVoice()

    enum Temperament: String, CaseIterable, Identifiable, Hashable {
        case dry
        case warm
        case quiet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dry: return "Dry"
            case .warm: return "Warm"
            case .quiet: return "Quiet"
            }
        }
    }

    enum Event {
        case morningGreeting
        case sent(destination: String)
        case copied
    }

    /// What the roost is currently saying, or empty.
    @Published private(set) var saying = ""

    var temperament: Temperament {
        get { Temperament(rawValue: UserDefaults.standard.string(forKey: Self.temperamentKey) ?? "") ?? .dry }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.temperamentKey)
            objectWillChange.send()
        }
    }

    var userName: String {
        get { UserDefaults.standard.string(forKey: Self.nameKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.nameKey)
            objectWillChange.send()
        }
    }

    private static let temperamentKey = "CawTemperament"
    private static let nameKey = "CawUserName"
    private static let greetedKey = "CawLastGreetingDay"

    /// Speaks short confirmations out loud — the user's own idea, so a send
    /// that lands late (waiting on a click) is announced instead of appearing
    /// like a ghost. HARD RULE: never speak while the microphone is open — the
    /// app's own voice would land in a transcript.
    private let synthesizer = AVSpeechSynthesizer()

    var speaksAloud: Bool {
        get { UserDefaults.standard.object(forKey: "CawSpeaksAloud") == nil ? true : UserDefaults.standard.bool(forKey: "CawSpeaksAloud") }
        set { UserDefaults.standard.set(newValue, forKey: "CawSpeaksAloud"); objectWillChange.send() }
    }

    func sayAloud(_ line: String) {
        guard speaksAloud else { return }
        guard !LiveTranscriptionController.shared.isRecording else { return }
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    private var clearTask: Task<Void, Never>?
    private var recentLines: [String] = []
    private var sendsSinceLastRemark = 0

    private init() {}

    /// Greets once per day, the first time the roost appears.
    func maybeGreet() {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        guard UserDefaults.standard.string(forKey: Self.greetedKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.greetedKey)
        speak(.morningGreeting)
    }

    func speak(_ event: Event) {
        // Quiet birds still greet; beyond that they mostly just exist.
        if temperament == .quiet {
            if case .sent = event {
                sendsSinceLastRemark += 1
                guard sendsSinceLastRemark >= 10 else { return }
                sendsSinceLastRemark = 0
            } else if case .copied = event {
                return
            }
        }

        guard var line = pick(for: event) else { return }
        line = line.replacingOccurrences(
            of: "{name}",
            with: userName.isEmpty ? "" : userName
        )
        // A line built around a missing name gets its gap tidied.
        line = line.replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        saying = line
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            self?.saying = ""
        }
    }

    private func pick(for event: Event) -> String? {
        let pool: [String]
        switch (event, temperament) {
        case (.morningGreeting, .dry):
            pool = [
                "Oh. You again. Good.",
                "Morning, {name}. The perch was fine without you, but fine.",
                "You're up. I noticed. That's all.",
                "Caw. That's the whole greeting.",
                "I've been awake for hours. Not waiting. Just awake.",
                "Morning. The cursor missed you. I stayed neutral.",
            ]
        case (.morningGreeting, .warm):
            pool = [
                "Morning, {name}. Good to hear you.",
                "There you are. Ready when you are.",
                "Morning. The perch is warm.",
                "Hello, {name}. Say the word — literally.",
            ]
        case (.morningGreeting, .quiet):
            pool = [
                "Morning, {name}.",
                "Here.",
                "Caw.",
            ]
        case (.sent, .dry):
            pool = [
                "Delivered. I don't do receipts.",
                "It's there. I watched it land. Riveting.",
                "Sent. My part was flawless, as usual.",
                "Off it went. I'd say I'm proud, but let's not.",
                "Another one delivered. The glamour never stops.",
                "Landed. You may continue.",
                "Done. I'll be over here, being a bird about it.",
                "Delivered again. At this point it's just showing off.",
            ]
        case (.sent, .warm):
            pool = [
                "Sent. Nice one.",
                "Delivered — it landed clean.",
                "That one's away. Good flow today, {name}.",
                "Off and landed. Keep going.",
            ]
        case (.sent, .quiet):
            pool = [
                "Sent.",
                "Landed.",
            ]
        case (.copied, .dry):
            pool = [
                "On the clipboard. Do with it what you will.",
                "Copied. The rest is your problem.",
                "Held. Not forever. Paste it somewhere.",
            ]
        case (.copied, .warm):
            pool = [
                "Copied — ⌘V when you're ready.",
                "Got it held for you.",
            ]
        case (.copied, .quiet):
            pool = []
        }

        let fresh = pool.filter { !recentLines.contains($0) }
        guard let line = (fresh.isEmpty ? pool : fresh).randomElement() else { return nil }
        recentLines.append(line)
        if recentLines.count > 6 { recentLines.removeFirst() }
        return line
    }
}
