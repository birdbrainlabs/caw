import SwiftUI

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var transcriber = LiveTranscriptionController.shared
    @StateObject private var insertion = TextInsertionController.shared
    @StateObject private var destinations = InsertionDestinations.shared
    @StateObject private var corpus = TrainingCorpus.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                appState: appState,
                transcriber: transcriber,
                insertion: insertion,
                destinations: destinations,
                corpus: corpus
            )
        } label: {
            Image(systemName: appState.isFnPressed ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel(AppEdition.displayName)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar menu, trimmed 2026-09-25 to five top-level items after the old
/// ~25-item flat menu became unreadable. Every control that used to live here
/// directly now lives in the Settings window (`SettingsView.swift`) instead —
/// same UserDefaults keys, same functions, no behavior change. See
/// HANDOFF.md, "Editions" section.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState
    @ObservedObject var transcriber: LiveTranscriptionController
    @ObservedObject var insertion: TextInsertionController
    @ObservedObject var destinations: InsertionDestinations
    @ObservedObject var corpus: TrainingCorpus
    #if !BETA
    @ObservedObject private var roost = RoostController.shared
    #endif

    var body: some View {
        Button("Talk to Crumb…") { CrumbChatWindow.shared.show() }

        #if !BETA
        if roost.isEnabled {
            Button("Open Home") { RoostController.shared.showWindow() }
        }
        #endif

        Menu("Send To") {
            Button("Choose App…") {
                destinations.addByBrowsing()
            }

            Divider()

            ForEach(destinations.candidates, id: \.self) { identifier in
                Button {
                    destinations.toggle(identifier)
                } label: {
                    Text("\(destinations.contains(identifier) ? "✓ " : "")\(destinations.name(for: identifier))")
                }
            }
        }

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit \(AppEdition.displayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
