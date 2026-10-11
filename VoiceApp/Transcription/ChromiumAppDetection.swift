import Foundation

/// Is this app built on Electron or Chromium? Those apps keep their
/// accessibility tree switched off until assistive software asks for it, so the
/// read-back test has to ask (`AXManualAccessibility`) and then give the tree a
/// moment to appear before it can find the focused text box.
///
/// Detected from the app's own bundle, not from its name: the Codex desktop app
/// calls itself "ChatGPT", lives at /Applications/ChatGPT.app and ships its
/// Electron framework renamed to "Codex Framework.framework". A name list would
/// never have caught it. The markers, any one of which is enough:
///
/// - `Contents/Frameworks/Electron Framework.framework` (Claude, Slack, VS Code…)
/// - `Contents/Frameworks/Chromium Embedded Framework.framework` (CEF apps)
/// - `Contents/Resources/app.asar` (Electron's packed app, kept even when the
///   framework is renamed)
/// - Info.plist keys `ElectronAsarIntegrity`, `ElectronTeamID` or
///   `ChromiumBaseVersion`
/// - `NSPrincipalClass` of `AtomApplication`, `ElectronApplication` (Electron)
///   or `BrowserCrApplication` (Chromium — Chrome, and Codex)
///
/// The bundle IDs in `knownBundleIDs` count regardless, as a fallback for
/// bundles that hide every marker.
///
/// Reads only the app's bundle on disk (its folder layout and Info.plist) —
/// nothing from the running app.
enum ChromiumAppDetection {
    static let knownBundleIDs: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.hnc.Discord",
    ]

    static let frameworkMarkers = [
        "Contents/Frameworks/Electron Framework.framework",
        "Contents/Frameworks/Chromium Embedded Framework.framework",
    ]
    static let resourceMarkers = ["Contents/Resources/app.asar"]
    static let infoPlistKeys = ["ElectronAsarIntegrity", "ElectronTeamID", "ChromiumBaseVersion"]
    static let principalClasses: Set<String> = ["AtomApplication", "ElectronApplication", "BrowserCrApplication"]

    /// Why the app counts as Electron/Chromium, or nil when it does not.
    static func marker(bundleURL: URL?, bundleID: String?) -> String? {
        if let bundleID, knownBundleIDs.contains(bundleID) { return "known:\(bundleID)" }
        guard let bundleURL else { return nil }
        let files = FileManager.default
        for path in frameworkMarkers + resourceMarkers
        where files.fileExists(atPath: bundleURL.appendingPathComponent(path).path) {
            return (path as NSString).lastPathComponent
        }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        if let key = infoPlistKeys.first(where: { info[$0] != nil }) { return key }
        if let principal = info["NSPrincipalClass"] as? String, principalClasses.contains(principal) {
            return principal
        }
        return nil
    }

    static func isChromiumBased(bundleURL: URL?, bundleID: String?) -> Bool {
        marker(bundleURL: bundleURL, bundleID: bundleID) != nil
    }
}
