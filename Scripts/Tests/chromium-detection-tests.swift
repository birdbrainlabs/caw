// ChromiumAppDetection against made-up app bundles in a temporary folder:
// Electron found by its framework, by app.asar when the framework is renamed
// (the Codex desktop app), by Info.plist keys and principal class; the
// bundle-ID fallback; and a plain native app left alone.
//
//   Scripts/run-tests.sh

import Foundation

@main
struct ChromiumDetectionTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func makeBundle(_ name: String, in folder: URL, dirs: [String] = [], files: [String] = [],
                           info: [String: Any] = [:]) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let files_ = FileManager.default
        try files_.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for dir in dirs {
            try files_.createDirectory(at: bundle.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in files {
            let url = bundle.appendingPathComponent(file)
            try files_.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        var plist: [String: Any] = ["CFBundleIdentifier": "test.\(name)"]
        plist.merge(info) { $1 }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("caw-chromium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let electron = try makeBundle("Electronish", in: folder,
                                      dirs: ["Contents/Frameworks/Electron Framework.framework"],
                                      info: ["NSPrincipalClass": "AtomApplication"])
        check(ChromiumAppDetection.isChromiumBased(bundleURL: electron, bundleID: "test.Electronish"),
              "Electron Framework.framework marks an Electron app")

        // The Codex desktop app: renamed framework, Chromium's principal class.
        let renamed = try makeBundle("ChatGPT", in: folder,
                                     dirs: ["Contents/Frameworks/Codex Framework.framework"],
                                     files: ["Contents/Resources/app.asar"],
                                     info: ["NSPrincipalClass": "BrowserCrApplication"])
        check(ChromiumAppDetection.marker(bundleURL: renamed, bundleID: "test.renamed") == "app.asar",
              "a renamed Electron framework is still found by app.asar")

        let plistOnly = try makeBundle("PlistOnly", in: folder, info: ["ChromiumBaseVersion": "154.0"])
        check(ChromiumAppDetection.marker(bundleURL: plistOnly, bundleID: "test.plist") == "ChromiumBaseVersion",
              "a Chromium Info.plist key is enough")

        let principal = try makeBundle("Principal", in: folder, info: ["NSPrincipalClass": "BrowserCrApplication"])
        check(ChromiumAppDetection.marker(bundleURL: principal, bundleID: "test.principal") == "BrowserCrApplication",
              "Chromium's principal class is enough")

        let native = try makeBundle("Native", in: folder, info: ["NSPrincipalClass": "NSApplication"])
        check(!ChromiumAppDetection.isChromiumBased(bundleURL: native, bundleID: "test.Native"),
              "a native AppKit app is not Chromium")
        check(!ChromiumAppDetection.isChromiumBased(bundleURL: nil, bundleID: nil),
              "no bundle and no ID is not Chromium")

        for id in ["com.openai.codex", "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
                   "com.microsoft.VSCode", "com.hnc.Discord"] {
            check(ChromiumAppDetection.isChromiumBased(bundleURL: native, bundleID: id),
                  "\(id) counts by bundle ID even without markers")
        }

        if failures == 0 { print("chromium-detection: all passed") } else { exit(1) }
    }
}
