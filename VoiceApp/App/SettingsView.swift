import SwiftUI

/// Everything that used to live as ~25 flat items in the menu bar menu, now a
/// plain settings window. Every control here reads and writes the exact same
/// `UserDefaults` key (or calls the exact same function) the old menu item
/// did — this is a repackaging, not a behavior change. See HANDOFF.md,
/// "Editions" section, for why the two builds differ.
struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var transcriber = LiveTranscriptionController.shared
    @ObservedObject private var insertion = TextInsertionController.shared
    @ObservedObject private var corpus = TrainingCorpus.shared
    @ObservedObject private var cawVoice = CawVoice.shared
    /// Same key and default as `ReadbackProbe.isEnabled`: on in Personal, off in Beta.
    @AppStorage(ReadbackProbe.enabledKey) private var readbackEnabled = !AppEdition.isBeta
    @State private var showingReadbackResults = false
    @StateObject private var wordFixes = WordFixEditorModel()
    #if !BETA
    @ObservedObject private var roost = RoostController.shared
    #endif

    private enum LogRetention: Hashable {
        case off, days30, days90, everything
    }

    var body: some View {
        Form {
            Section("Look") {
                Picker("Orb Size", selection: orbDiameterBinding) {
                    ForEach(Self.orbSizes, id: \.self) { size in
                        Text("\(size) pt").tag(size)
                    }
                }

                Picker("Orb Style", selection: orbStyleBinding) {
                    Text("Crumb").tag("crumb")
                    Text("Orb").tag("raven")
                    Text("Egg").tag("egg")
                }

                Button("Show Voice Pill") {
                    FloatingPillController.shared.show()
                }

                Button("Reset Pill Position") {
                    FloatingPillController.shared.resetPosition()
                }
            }

            Section("Listening") {
                Text(appState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transcriber.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Speech Engine", selection: speechEngineBinding) {
                    Text("New (macOS 26) — 4× fewer errors").tag("new")
                    Text("Classic").tag("classic")
                }

                Toggle("End Recording After Silence", isOn: $transcriber.endsOnSilence)
                Text("Clicked recordings only, never while Fn is held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Punctuate Automatically", isOn: punctuateBinding)
                Text("Adds sentence breaks before the words land. Off is faster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !appState.isMonitoring {
                    Button("Enable Hold-Fn Shortcut…") {
                        appState.requestPermissionAndRetry()
                    }
                }
            }

            Section("Crumb") {
                Picker("\(AppEdition.brandName)'s Voice", selection: temperamentBinding) {
                    ForEach(CawVoice.Temperament.allCases) { temperament in
                        Text(temperament.title).tag(temperament)
                    }
                }

                Toggle("\(AppEdition.brandName) Speaks Aloud", isOn: speaksAloudBinding)

                TextField("What Should \(AppEdition.brandName) Call You", text: userNameBinding, prompt: Text("Leave empty for no name"))
                Text("A name or nickname for greetings. It stays on this Mac, like everything else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WordFixesSections(model: wordFixes)

            Section("Dictation Log") {
                Picker("Keep Dictation Log", selection: logRetentionBinding) {
                    Text("Off — Don't Save").tag(LogRetention.off)
                    Text("30 Days").tag(LogRetention.days30)
                    Text("90 Days").tag(LogRetention.days90)
                    Text("Keep Everything").tag(LogRetention.everything)
                }

                Toggle("Archive Older Entries Instead of Deleting", isOn: $corpus.archivesOldEntries)

                Button("Show Training Corpus") {
                    corpus.revealInFinder()
                }

                Button("Delete Training Corpus") {
                    corpus.deleteEverything()
                }
            }

            #if !BETA
            if RoostController.isAvailable {
                Section("Home") {
                    Toggle("Home dashboard", isOn: Binding(
                        get: { roost.isEnabled },
                        set: { roost.setEnabled($0) }
                    ))
                }
            }
            #endif

            Section("Permissions") {
                if insertion.canInsertIntoApps {
                    Text("Words go straight to where your cursor is")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(AppEdition.displayName) copies to the clipboard — you press ⌘V",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Button("Request Microphone & Speech Permissions") {
                    transcriber.requestPermissions()
                }

                Button("Open Microphone Privacy Settings") {
                    transcriber.openPrivacySettings()
                }

                if !appState.isMonitoring {
                    Button("Open Input Monitoring Settings") {
                        appState.openInputMonitoringSettings()
                    }
                }

                // Opens by itself only on a Beta tester's first launch; here in
                // both editions so the owner can see what testers see.
                Button("Run Setup Again…") {
                    SetupWindow.shared.show()
                }
            }

            // A plain, always-open section. It was a DisclosureGroup, but on macOS
            // a collapsed group opens only from its tiny chevron, and the owner
            // could not open it.
            Section("Troubleshooting") {
                Button("Show Insertion Log") {
                    InsertionAuditLog.shared.prepareForViewing()
                    NSWorkspace.shared.open(InsertionAuditLog.shared.fileURL)
                }

                Toggle("Read-back test", isOn: $readbackEnabled)
                Text("After each dictation, checks whether \(AppEdition.displayName) can read the text box back. Changes nothing you see. Never reads password fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Read-back results…") {
                    showingReadbackResults = true
                }
            }
        }
        .sheet(isPresented: $showingReadbackResults) {
            ReadbackResultsView()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420, idealHeight: 760)
        .onAppear { wordFixes.reload() }
        .onDisappear { wordFixes.saveNow() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            wordFixes.reload()
        }
    }

    // MARK: - Bindings onto the same UserDefaults keys / functions the old menu used

    private static let orbSizes = [48, 64, 80, 96, 128, 160, 200]

    private var orbDiameterBinding: Binding<Int> {
        Binding(
            get: {
                let stored = UserDefaults.standard.double(forKey: "OrbDiameter")
                return stored > 0 ? Int(stored) : 48
            },
            set: {
                UserDefaults.standard.set(Double($0), forKey: "OrbDiameter")
                FloatingPillController.shared.reloadOrb()
            }
        )
    }

    private var orbStyleBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "OrbStyle") ?? "raven" },
            set: { newValue in
                if newValue == "raven" {
                    UserDefaults.standard.removeObject(forKey: "OrbStyle")
                } else {
                    UserDefaults.standard.set(newValue, forKey: "OrbStyle")
                }
                FloatingPillController.shared.reloadOrb()
            }
        )
    }

    private var speechEngineBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "SpeechEngineClassic") ? "classic" : "new" },
            set: { UserDefaults.standard.set($0 == "classic", forKey: "SpeechEngineClassic") }
        )
    }

    private var punctuateBinding: Binding<Bool> {
        Binding(
            get: { FloatingPillController.punctuatesAutomatically },
            set: { UserDefaults.standard.set($0, forKey: "PunctuateBeforePaste") }
        )
    }

    private var temperamentBinding: Binding<CawVoice.Temperament> {
        Binding(
            get: { cawVoice.temperament },
            set: { cawVoice.temperament = $0 }
        )
    }

    private var speaksAloudBinding: Binding<Bool> {
        Binding(
            get: { cawVoice.speaksAloud },
            set: { cawVoice.speaksAloud = $0 }
        )
    }

    private var userNameBinding: Binding<String> {
        Binding(
            get: { cawVoice.userName },
            set: { cawVoice.userName = $0 }
        )
    }

    private var logRetentionBinding: Binding<LogRetention> {
        Binding(
            get: {
                guard corpus.isEnabled else { return .off }
                switch corpus.retentionDays {
                case 30: return .days30
                case 90: return .days90
                default: return .everything
                }
            },
            set: { newValue in
                switch newValue {
                case .off:
                    corpus.isEnabled = false
                case .days30:
                    corpus.isEnabled = true
                    corpus.retentionDays = 30
                case .days90:
                    corpus.isEnabled = true
                    corpus.retentionDays = 90
                case .everything:
                    corpus.isEnabled = true
                    corpus.retentionDays = 0
                }
            }
        )
    }
}
