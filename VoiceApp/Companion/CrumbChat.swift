import AppKit
import SwiftUI
import FoundationModels
import Carbon

@MainActor final class CrumbChatActivity: ObservableObject {
    static let shared = CrumbChatActivity()
    @Published var thinking = false
}

@MainActor final class CrumbChatWindow: NSObject, NSWindowDelegate {
    static let shared = CrumbChatWindow()
    private var window: NSWindow?
    var isKey: Bool { window?.isKeyWindow == true && NSApp.isActive }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 530, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Talk to Crumb"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 440, height: 500)
            if #available(macOS 26.0, *) {
                window.contentView = NSHostingView(rootView: CrumbChatView())
            } else {
                window.contentView = NSHostingView(rootView: Text("Talking to Crumb needs macOS 26 or newer.").padding(32))
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .crumbFocusInput, object: nil)
    }
    func windowWillClose(_ notification: Notification) {
        if #available(macOS 26.0, *) { CrumbChatModel.shared.stop() }
    }
}

@available(macOS 26.0, *)
@MainActor final class CrumbChatModel: ObservableObject {
    static let shared = CrumbChatModel()
    struct Message: Identifiable { let id = UUID(); let user: Bool; var text: String }
    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings to chat with Crumb."
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple's local language model."
        case .unavailable(.modelNotReady): return "Apple's local model is still downloading. Try again when it is ready."
        case .unavailable: return "Apple's local model is unavailable right now."
        }
    }
    func receiveDictation(_ text: String) {
        draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
        NotificationCenter.default.post(name: .crumbFocusInput, object: nil)
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        guard unavailable == nil else { error = unavailable; return }
        guard text.count <= 1500 else { error = "Try a shorter message—up to 1,500 characters."; return }
        // Bound context to leave room for the model's reply. Never read dictation.
        let recent = messages.suffix(4).map { "\($0.user ? "User" : "Crumb"): \(String($0.text.prefix(550)))" }.joined(separator: "\n")
        messages.append(Message(user: true, text: text))
        draft = ""; error = nil; busy = true
        CrumbChatActivity.shared.thinking = true
        let token = UUID(); generation = token
        task = Task {
            do {
                let session = LanguageModelSession(instructions: """
                You are Crumb, a friendly little meatball with spaghetti arms and a bottle-cap hat, created by Birdbrain Labs. Be warm, curious, gently funny, and useful. Speak naturally in first person; use food jokes sparingly. Usually answer in one to three short sentences. Do not narrate actions or use stage directions. You are an AI desktop companion, not a human. Be honest when unsure. You cannot see the screen, access files, browse, or perform actions. Never claim you did. If the user asks you to look something up online, say plainly that you cannot browse. Do not pretend to search or ask needless follow-up questions. Do not steer unrelated requests toward meatballs. Do not prefix your reply with your name. Only use what the user tells you in this chat. You remember only the recent conversation included below. Do not invent memories or facts about the user.
                """)
                let response = try await session.respond(to: "Recent conversation:\n\(recent)\n\nUser: \(text)", options: GenerationOptions(maximumResponseTokens: 220))
                guard !Task.isCancelled, generation == token else { return }
                let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.isEmpty { error = "Crumb couldn't form a reply. Try rephrasing." }
                else { messages.append(Message(user: false, text: reply)) }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = "Crumb couldn't answer: \(error.localizedDescription)"
            }
            guard generation == token else { return }
            busy = false; CrumbChatActivity.shared.thinking = false; task = nil
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard let self, self.busy, self.generation == token else { return }
            self.stop(); self.error = "That reply took too long. Please try a shorter message."
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        busy = false; CrumbChatActivity.shared.thinking = false
    }
    func clear() { stop(); messages.removeAll(); error = nil; draft = "" }
}

@available(macOS 26.0, *)
struct CrumbChatView: View {
    @ObservedObject private var chat = CrumbChatModel.shared
    @ObservedObject private var shortcut = CrumbShortcut.shared
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Talk to Crumb").font(.title2.bold())
                    Text("Local chat on this Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New chat") { chat.clear() }.disabled(chat.messages.isEmpty && !chat.busy)
            }
            HStack {
                Picker("Open Crumb", selection: Binding(get: { shortcut.choice }, set: { shortcut.setChoice($0) })) {
                    ForEach(CrumbShortcut.Choice.allCases) { option in Text(option.label).tag(option) }
                }.frame(maxWidth: 320)
                Spacer()
            }
            if let issue = shortcut.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            Text("Crumb is ready to meet you. Try asking him for a tiny game idea, or tell him how your day is going.")
                                .foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.user ? "You" : "Crumb").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(message.user ? Color.primary.opacity(0.05) : Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                        if chat.busy { HStack { ProgressView().controlSize(.small); Text("Crumb is thinking…") }.id("thinking") }
                    }
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if let reason = chat.error ?? chat.unavailable {
                Text(reason).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(alignment: .bottom) {
                TextField("Type a message to Crumb…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        chat.send(); return .handled
                    }
                    .accessibilityLabel("Message to Crumb")
                if chat.busy { Button("Stop") { chat.stop() } }
                else { Button("Send") { chat.send() }.buttonStyle(.borderedProminent)
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.unavailable != nil) }
            }
            HStack {
                Spacer()
                Text("Return: chat · Shift+Return: new line").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Chat stays on this Mac. Fn fills this box when this window is active.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 400, minHeight: 440)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .crumbFocusInput)) { _ in focused = true }
    }
}


extension Notification.Name {
    static let crumbFocusInput = Notification.Name("CrumbFocusInput")
}

/// Registers one explicit shortcut, without monitoring other keystrokes.
@MainActor final class CrumbShortcut: ObservableObject {
    static let shared = CrumbShortcut()
    enum Choice: String, CaseIterable, Identifiable {
        case optionSpace, controlOptionSpace, controlShiftSpace, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .optionSpace: return "Option + Space"
            case .controlOptionSpace: return "Control + Option + Space"
            case .controlShiftSpace: return "Control + Shift + Space"
            case .off: return "Off"
            }
        }
        var modifiers: UInt32 {
            switch self {
            case .optionSpace: return UInt32(optionKey)
            case .controlOptionSpace: return UInt32(controlKey | optionKey)
            case .controlShiftSpace: return UInt32(controlKey | shiftKey)
            case .off: return 0
            }
        }
    }
    @Published private(set) var choice = Choice(rawValue: UserDefaults.standard.string(forKey: "CrumbOpenShortcut") ?? "") ?? .optionSpace
    @Published private(set) var issue: String?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    func start() {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x43524D42, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in CrumbChatWindow.shared.show() }
                return noErr
            }, 1, &type, nil, &handler)
            guard status == noErr else { issue = "Couldn’t enable the shortcut. Open Crumb from \(AppEdition.brandName)’s menu."; return }
        }
        register()
    }
    func setChoice(_ choice: Choice) {
        self.choice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "CrumbOpenShortcut")
        register()
    }
    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        issue = nil
        guard choice != .off else { return }
        let status = RegisterEventHotKey(UInt32(kVK_Space), choice.modifiers,
            EventHotKeyID(signature: 0x43524D42, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { issue = "This shortcut is unavailable or already in use. Choose another combination above." }
    }
}
