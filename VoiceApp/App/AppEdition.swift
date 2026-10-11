import Foundation

/// Which build this is. One codebase, two editions, chosen by the build
/// configuration (Debug/Release = Personal, Debug-Beta/Release-Beta = Beta):
///
/// - **Personal** — the owner's own app. Bundle ID `com.local.VoiceApp`, data in
///   `~/Library/Application Support/VoiceApp`, behaviour exactly as before.
/// - **Beta** — the testers' app. Its own bundle ID (so its own preferences
///   domain and its own privacy permissions), and its own data folder named
///   after that bundle ID. It never reads or writes the Personal edition's data.
///
/// The Swift compilation condition `BETA` decides at compile time, so anything
/// personal can be compiled out of the Beta binary entirely. The Info.plist key
/// `CawEdition` carries the same answer for anything that inspects the bundle.
enum AppEdition {
    #if BETA
    static let isBeta = true
    #else
    static let isBeta = false
    #endif

    /// The name people see — the `APP_DISPLAY_NAME` build setting.
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Caw"
    }

    /// The product's name in sentences ("Caw can learn…"). Personal is the
    /// owner's Caw, whatever its bundle is called; Beta is its display name
    /// without a trailing "Beta", so the copy follows a rename.
    static var brandName: String {
        #if BETA
        let name = displayName
        return name.hasSuffix(" Beta") ? String(name.dropLast(5)) : name
        #else
        return "Caw"
        #endif
    }

    /// This edition's folder in Application Support. Personal keeps the folder
    /// it has always used; Beta derives its folder from its own bundle ID.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if BETA
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.birdbrainlabs.dictation.beta", isDirectory: true)
        #else
        return base.appendingPathComponent("VoiceApp", isDirectory: true)
        #endif
    }

    /// A dispatch-queue label scoped to this edition's bundle ID.
    static func queueLabel(_ name: String) -> String {
        "\(Bundle.main.bundleIdentifier ?? "app").\(name)"
    }
}
