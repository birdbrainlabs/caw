import AppKit
import Combine
import UniformTypeIdentifiers

/// The apps picked in the menu bar's "Send To" list.
///
/// Since the review card and spoken commands were removed (2026-10-02) nothing
/// is sent to these apps any more. What remains is that their names are given
/// to the Classic speech engine as recognition hints (`contextualStrings`), so
/// "Claude" is not heard as "cloud".
@MainActor
final class InsertionDestinations: ObservableObject {
    static let shared = InsertionDestinations()

    /// Bundle identifiers, in the order the user arranged them.
    @Published private(set) var chosen: [String] = []

    /// Bumped when apps launch or quit so the menu re-renders.
    @Published private(set) var runningRevision = 0

    /// Destination names, resolved once and cached. Resolving a bundle identifier
    /// can hit Launch Services, which is far too slow to do on the main thread
    /// while a recording is starting.
    @Published private(set) var chosenNames: [String] = []

    private static let chosenDefaultsKey = "InsertionDestinations"
    private static let namesDefaultsKey = "InsertionDestinationNames"

    /// Remembered so a destination that isn't running still shows its real name.
    private var rememberedNames: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        chosen = UserDefaults.standard.stringArray(forKey: Self.chosenDefaultsKey) ?? []
        rememberedNames = UserDefaults.standard.dictionary(forKey: Self.namesDefaultsKey) as? [String: String] ?? [:]
        refreshChosenNames()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor [weak self] in
                        self?.runningRevision += 1
                    }
                }
            )
        }
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        chosen.contains(bundleIdentifier)
    }

    func toggle(_ bundleIdentifier: String) {
        if let index = chosen.firstIndex(of: bundleIdentifier) {
            chosen.remove(at: index)
        } else {
            chosen.append(bundleIdentifier)
            if let application = runningApplication(for: bundleIdentifier), let name = application.localizedName {
                rememberedNames[bundleIdentifier] = name
                UserDefaults.standard.set(rememberedNames, forKey: Self.namesDefaultsKey)
            }
        }

        UserDefaults.standard.set(chosen, forKey: Self.chosenDefaultsKey)
        refreshChosenNames()
    }

    private func refreshChosenNames() {
        var seen = Set<String>()
        chosenNames = chosen
            .map { name(for: $0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(100)
            .map { $0 }
    }

    /// Apps that can be picked: everything with a normal user interface that is
    /// running now, plus anything already chosen so it never disappears from the
    /// menu just because it is closed.
    var candidates: [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap(\.bundleIdentifier)

        var seen = Set<String>()
        return (chosen + running.sorted { name(for: $0) < name(for: $1) }).filter { seen.insert($0).inserted }
    }

    /// Apps that are not running never appear in the running-apps list, so a
    /// destination you only use occasionally could not be added at all.
    func addByBrowsing() {
        NSApp.activate()

        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard
            panel.runModal() == .OK,
            let url = panel.url,
            let identifier = Bundle(url: url)?.bundleIdentifier
        else {
            return
        }

        rememberedNames[identifier] = url.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(rememberedNames, forKey: Self.namesDefaultsKey)

        guard !chosen.contains(identifier) else { return }
        chosen.append(identifier)
        UserDefaults.standard.set(chosen, forKey: Self.chosenDefaultsKey)
        refreshChosenNames()
    }

    func runningApplication(for bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    func name(for bundleIdentifier: String) -> String {
        if let running = runningApplication(for: bundleIdentifier)?.localizedName {
            return running
        }
        if let remembered = rememberedNames[bundleIdentifier] {
            return remembered
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleIdentifier
    }
}
