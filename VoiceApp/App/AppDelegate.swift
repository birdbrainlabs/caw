import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // First launch: Crumb is the mascot. Later choices in Orb Style persist.
        if !UserDefaults.standard.bool(forKey: "CrumbMascotInstalledV1") {
            UserDefaults.standard.set("crumb", forKey: "OrbStyle")
            UserDefaults.standard.set(true, forKey: "CrumbMascotInstalledV1")
        }
        // Personal: writes the owner's existing word fixes on first launch.
        // Beta: writes an empty list. Never overwrites an existing file.
        WordFixStore.shared.ensureFileExists()
        // Phase 2b: the first launch of this build counts the word swaps in the
        // read-back log already on disk toward suggested fixes. Once only.
        WordFixCandidateStore.shared.backfillOnceInBackground(probeLog: ReadbackProbe.shared.fileURL)
        AppState.shared.start()
        CrumbShortcut.shared.start()
        // Phase 2c: a Beta tester's first launch walks through permissions.
        SetupWindow.showIfNeeded()
        #if !BETA
        RoostController.shared.start()
        if CommandLine.arguments.contains("--home-nest") { RoostController.shared.dock() }
        #endif
        if CommandLine.arguments.contains("--talk-to-crumb") { CrumbChatWindow.shared.show() }

        // Download the new speech engine's model assets before the first
        // dictation ever needs them.
        if #available(macOS 26.0, *) {
            ModernSpeechEngine.preflight()
        }

        if CommandLine.arguments.contains("--mic-test") {
            MicrophoneSelfTest.run()
        }

        // Measures whether a destination will tell us it has a focused text field.
        if CommandLine.arguments.contains("--focus-probe") {
            Task { @MainActor in
                for target in ["com.anthropic.claudefordesktop"] {
                    TextInsertionController.shared.probeFocusVisibility(of: target)
                }
            }
        }

        // Verifies the DIRECT path — the one every dictation now takes — against
        // whatever the caret is really in. Waits a moment first so the tester can
        // click into a window; this app is a menu-bar app and never takes focus,
        // which is the property being tested.
        if CommandLine.arguments.contains("--cursor-test") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "PasteTest")
                switch await TextInsertionController.shared.insertAtCursor("VOICEAPP-CURSOR-TEST-12345") {
                case .success:
                    logger.notice("CURSOR TEST reported success")
                case .failure(let error):
                    logger.error("CURSOR TEST failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Verifies the whole insertion path against a real app, so it can be
        // checked without a person watching a window.
        if let index = CommandLine.arguments.firstIndex(of: "--paste-test"),
           index + 1 < CommandLine.arguments.count {
            let target = CommandLine.arguments[index + 1]
            Task { @MainActor in
                let result = await TextInsertionController.shared.insert("VOICEAPP-PASTE-TEST-12345", into: target)
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "PasteTest")
                switch result {
                case .success:
                    logger.notice("PASTE TEST reported success into \(target, privacy: .public)")
                case .failure(let error):
                    logger.error("PASTE TEST failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}
