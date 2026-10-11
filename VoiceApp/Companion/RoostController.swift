import AppKit
import Combine
import SwiftUI
import WebKit

// The Home nest is the owner's own local dashboard. This whole file is Personal
// edition only: the Beta build has no nest, no localhost connection, no
// launcher and no Home menu items. Every call site is behind `#if !BETA` too.
// The dashboard itself (a Contents/Resources/Home folder) is not part of the
// public source; without it Home stays off and its menu items are hidden.
#if !BETA

/// One native mascot, either on the desktop or in Home's nest.
@MainActor
final class RoostController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RoostController()
    @Published private(set) var isDocked = false
    @Published var dashboardThinking = false
    @Published var dashboardDelivery = 0
    @Published var dictationDelivery = 0
    var isKey: Bool { window?.isKeyWindow == true }
    private var window: NSWindow?
    private var polling = false
    private var lastHomeRequest = ""
    private var webView: WKWebView?
    /// True whenever the webview is showing the "Starting Home…" fallback
    /// instead of the real dashboard. Drives the native retry timer and tells
    /// `showWindow()`/`dock()` to force a reload instead of leaving the user
    /// parked on the fallback.
    private var isShowingFallback = false
    private var fallbackSince: Date?
    private var nativeRetryTimer: Timer?
    /// The navigation token for the fallback HTML's own load, so its `didFinish`
    /// isn't mistaken for the real dashboard coming back.
    private var pendingFallbackNavigation: WKNavigation?
    /// Home's two Python servers, once this app has started them. Held so the
    /// `Process` objects live as long as the app; each is launched at most
    /// once per app run.
    private var homeServer: Process?
    private var homeSearchServer: Process?
    private var homeServerTried = false
    private var homeSearchServerTried = false
    private var checkingServices = false

    /// True when this app bundle carries the Home folder. Without it Home is
    /// always off: no localhost polling, no launcher, no menu items or setting.
    static let isAvailable: Bool = {
        guard let home = Bundle.main.resourceURL?.appendingPathComponent("Home", isDirectory: true) else { return false }
        return FileManager.default.fileExists(atPath: home.path)
    }()
    /// The `homeEnabled` setting: on unless turned off, and only when Home is
    /// bundled. Off means no localhost polling, no launching Home, and no
    /// Home menu items.
    static let enabledDefaultsKey = "homeEnabled"
    static var enabled: Bool {
        isAvailable && (UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true)
    }
    /// Mirrors `enabled` so menus redraw when it changes.
    @Published private(set) var isEnabled = RoostController.enabled

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledDefaultsKey)
        isEnabled = Self.enabled
        if isEnabled { start() } else { stop() }
    }
    // No snapping to the entire dashboard window on an ordinary desktop drag.
    var frame: NSRect? { nil }
    static var dockedOrbDiameter: CGFloat { FloatingPillController.orbDiameter * 1.5 }

    /// Nothing runs on a timer. Home is only asked for its state when its
    /// window is shown or Crumb docks — he never checks on it by himself.
    func start() { }
    /// Stops polling and closes the nest. Nothing reconnects until re-enabled.
    func stop() {
        let closing = window
        window = nil
        webView = nil
        closing?.delegate = nil
        closing?.close()
        isDocked = false
        dashboardThinking = false
        dashboardDelivery = 0
        stopNativeRetryTimer()
        isShowingFallback = false
        fallbackSince = nil
        FloatingPillController.shared.reloadOrb()
    }

    /// Starts Home's two servers if they are not answering. Called only when
    /// the user opens Home or docks Crumb (and from the retry paths of a window
    /// that is already open) — never at launch and never on a timer. Home's
    /// code ships inside this app at Contents/Resources/Home; its personal data
    /// lives in ~/Library/Application Support/VoiceApp/Home (HOME_DATA_DIR).
    /// Each server is asked once (1 s) and launched at most once per app run;
    /// a server that is already answering — whoever started it — is left alone.
    private func ensureLocalServices() async {
        guard Self.enabled, !checkingServices,
              !(homeServerTried && homeSearchServerTried) else { return }
        checkingServices = true
        defer { checkingServices = false }
        if !homeServerTried, !(await Self.answers("http://127.0.0.1:4194/api/version")) {
            homeServerTried = true
            homeServer = Self.launchHomeScript("server.py")
        }
        if !homeSearchServerTried, !(await Self.answers("http://127.0.0.1:4195/api/nest")) {
            homeSearchServerTried = true
            homeSearchServer = Self.launchHomeScript("job_search_server.py")
        }
    }

    /// One loopback GET with a 1 s limit; any HTTP reply counts as answering.
    private static func answers(_ address: String) async -> Bool {
        var req = URLRequest(url: URL(string: address)!)
        req.timeoutInterval = 1
        req.setValue("http://127.0.0.1:4194", forHTTPHeaderField: "Origin")
        return (try? await URLSession.shared.data(for: req)).map { $0.1 is HTTPURLResponse } ?? false
    }

    /// Runs `/usr/bin/python3 <script>` from the bundled Home folder. Python is
    /// told not to write bytecode, so nothing is ever written inside the
    /// signed app bundle; all data goes to HOME_DATA_DIR.
    private static func launchHomeScript(_ script: String) -> Process? {
        guard let home = Bundle.main.resourceURL?.appendingPathComponent("Home", isDirectory: true),
              FileManager.default.fileExists(atPath: home.appendingPathComponent(script).path),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script]
        task.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["HOME_DATA_DIR"] = support.appendingPathComponent("VoiceApp/Home", isDirectory: true).path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = env
        do { try task.run() } catch { return nil }
        return task
    }
    func refresh() { }

    /// Shows the nest window, brought to front, without docking Crumb — he
    /// stays floating on the desktop exactly where he is, in the same state.
    /// While undocked the window renders its own compact "Home"
    /// state (see `HomeNestView`'s `expanded`/`isDocked` checks), which
    /// already exists for this case.
    func showWindow() {
        guard Self.enabled else { return }
        presentWindow()
        if isShowingFallback { retryDashboard() }
        Task { await sync() }
    }

    func dock() {
        guard Self.enabled else { return }
        presentWindow()
        if isShowingFallback { retryDashboard() }
        isDocked = true
        FloatingPillController.shared.reloadOrb()
        Task { await sync() }
    }

    /// Creates the nest window if needed and brings it to front. Shared by
    /// `dock()` and `showWindow()`; neither `isDocked` nor Crumb's floating
    /// state is touched here.
    private func presentWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 1180, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Home"
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 860, height: 620)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: HomeNestView(roost: self))
            w.setFrameAutosaveName("HomeNestWindow")
            self.window = w
        }
        Task { await ensureLocalServices() }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func undock() {
        isDocked = false
        FloatingPillController.shared.reloadOrb()
        Task { await sync() }
    }
    func windowWillClose(_ notification: Notification) { undock() }
    func windowWillMiniaturize(_ notification: Notification) { undock() }
    func attach(_ web: WKWebView) { webView = web }
    func receiveDictation(_ text: String) async -> Bool {
        guard let web = webView, let data = try? JSONSerialization.data(withJSONObject: [text]),
              let encoded = String(data: data, encoding: .utf8) else { return false }
        let script = """
        (() => { const text = \(encoded)[0]; let el=document.activeElement;
        if (!(el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && ['text','search','url','email'].includes(el.type)))) el=document.querySelector('#ask-input');
        if (!el || el.disabled || el.readOnly) return false;
        const panel=el.closest('.briefing');if(panel)panel.hidden=false;
        el.focus();const start=el.selectionStart??el.value.length,end=el.selectionEnd??start;
        el.setRangeText(text,start,end,'end');el.dispatchEvent(new Event('input',{bubbles:true}));return true; })()
        """
        do {
            let result = try await web.evaluateJavaScript(script)
            if result as? Bool == true { dictationDelivery += 1; return true }
        } catch { }
        return false
    }

    func retryDashboard() {
        guard Self.enabled else { return }
        Task { await ensureLocalServices() }
        webView?.load(URLRequest(url: URL(string: "http://127.0.0.1:4194/")!))
    }

    /// A real navigation to the dashboard failed outright (server not answering
    /// yet). Start the services if this run hasn't yet, and put up the fallback
    /// instead of a dead-end page — never mentions launchers or Terminal.
    func dashboardDidFail(_ webView: WKWebView) {
        Task { await ensureLocalServices() }
        showFallback(in: webView)
    }

    /// A navigation finished. Only clear the fallback state if this was the
    /// real dashboard loading, not the fallback HTML's own completion.
    func dashboardDidFinish(_ navigation: WKNavigation!) {
        if navigation != nil, navigation === pendingFallbackNavigation {
            pendingFallbackNavigation = nil
            return
        }
        isShowingFallback = false
        fallbackSince = nil
        stopNativeRetryTimer()
    }

    private func showFallback(in webView: WKWebView) {
        if !isShowingFallback {
            isShowingFallback = true
            fallbackSince = Date()
        }
        startNativeRetryTimer()
        let elapsed = fallbackSince.map { Date().timeIntervalSince($0) } ?? 0
        let message = elapsed > 30
            ? "Home is taking longer than usual. Still trying…"
            : "Starting Home…"
        pendingFallbackNavigation = webView.loadHTMLString(Self.fallbackHTML(message: message),
            baseURL: URL(string: "http://127.0.0.1:4194/"))
    }

    private func startNativeRetryTimer() {
        guard nativeRetryTimer == nil else { return }
        nativeRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isShowingFallback else { return }
                self.webView?.load(URLRequest(url: URL(string: "http://127.0.0.1:4194/")!))
            }
        }
    }

    private func stopNativeRetryTimer() {
        nativeRetryTimer?.invalidate()
        nativeRetryTimer = nil
    }

    /// Dark colours and system font match the docked/undocked nest chrome.
    /// Says nothing about launchers, Terminal, or right-click menus — the
    /// page recovers on its own or with the one visible Reload button.
    private static func fallbackHTML(message: String) -> String {
        """
        <html><body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;\
        justify-content:center;gap:20px;background:#0c1424;color:#e5edf9;font:18px -apple-system,system-ui;\
        text-align:center;padding:40px;box-sizing:border-box">
        <p style="margin:0;font-size:20px">\(message)</p>
        <button onclick="location.replace('http://127.0.0.1:4194/')" style="font:600 17px -apple-system,system-ui;\
        color:#0c1424;background:#e5edf9;border:none;border-radius:10px;padding:14px 34px;cursor:pointer">Reload</button>
        <script>
        (function () {
            function poll() {
                fetch('http://127.0.0.1:4194/api/version', { cache: 'no-store' })
                    .then(function (r) { if (r.ok) { location.replace('http://127.0.0.1:4194/'); } else { setTimeout(poll, 1500); } })
                    .catch(function () { setTimeout(poll, 1500); });
            }
            poll();
        })();
        </script>
        </body></html>
        """
    }

    private func sync() async {
        guard Self.enabled, !polling else { return }
        polling = true
        defer { polling = false }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:4194/api/nest/state")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("http://127.0.0.1:4194", forHTTPHeaderField: "Origin")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["docked": isDocked])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            dashboardThinking = state["thinking"] as? Bool ?? false
            dashboardDelivery = state["delivery"] as? Int ?? 0
            if let request = state["homeRequest"] as? String, !request.isEmpty, request != lastHomeRequest {
                lastHomeRequest = request
                dock()
            }
        } catch { dashboardThinking = false }
        var searchRequest = URLRequest(url: URL(string: "http://127.0.0.1:4195/api/nest")!)
        searchRequest.timeoutInterval = 1
        searchRequest.setValue("http://127.0.0.1:4194", forHTTPHeaderField: "Origin")
        if let (data, _) = try? await URLSession.shared.data(for: searchRequest),
           let search = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dashboardThinking = dashboardThinking || (search["thinking"] as? Bool ?? false)
            dashboardDelivery += search["delivery"] as? Int ?? 0
        }
    }
}

private struct HomeNestView: View {
    @ObservedObject var roost: RoostController
    @State private var dragging = false
    // Retain the full gesture surface until a drag handoff has ended.
    private var expanded: Bool { roost.isDocked || dragging }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HomeDashboard(roost: roost)
            VStack(spacing: 0) {
                Text("HOME").font(.system(size: 9, weight: .semibold)).tracking(2)
                    .frame(height: expanded ? 11 : 0)
                    .opacity(expanded ? 1 : 0)
                    .accessibilityHidden(!expanded)
                // Keep the gesture's view alive throughout the desktop handoff.
                CrumbMascotView(shown: roost.isDocked)
                    .frame(width: expanded ? 150 : 0, height: expanded ? 128 : 0)
                    .opacity(roost.isDocked ? 1 : 0)
                    .contentShape(Rectangle())
                    .allowsHitTesting(roost.isDocked || dragging)
                    .gesture(DragGesture(minimumDistance: 5)
                        .onChanged { _ in
                            if !dragging {
                                dragging = true
                                roost.undock()
                                FloatingPillController.shared.pickUpFromRoost()
                            } else { FloatingPillController.shared.continueDrag() }
                        }
                        .onEnded { _ in
                            FloatingPillController.shared.endDrag()
                            dragging = false
                        })
                    .accessibilityLabel("Crumb at home. Drag him onto your desktop.")
                    .accessibilityHidden(!roost.isDocked)
                Button(roost.isDocked ? "Come with me" : "Go home") {
                    if roost.isDocked { roost.undock() } else { roost.dock() }
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
            .padding(expanded ? 10 : 8)
            .frame(width: expanded ? 180 : 140, height: expanded ? 180 : 34)
            .foregroundStyle(Color(red: 0.90, green: 0.94, blue: 0.99))
            .background(Color(red: 0.08, green: 0.14, blue: 0.23), in: RoundedRectangle(cornerRadius: expanded ? 18 : 9))
            .overlay(RoundedRectangle(cornerRadius: expanded ? 18 : 9).strokeBorder(Color(red: 0.28, green: 0.39, blue: 0.54)))
            .shadow(color: .black.opacity(expanded ? 0.10 : 0.04), radius: expanded ? 10 : 3, y: expanded ? 3 : 1)
            .preferredColorScheme(.dark)
            .contextMenu { Button("Reload dashboard") { roost.retryDashboard() } }
            .padding(.trailing, 16)
            .padding(.top, expanded ? 16 : 24)
        }
    }
}

private struct HomeDashboard: NSViewRepresentable {
    let roost: RoostController
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Native Caw owns the mascot, even before the first server heartbeat.
        let script = "document.documentElement.classList.add('native-nest');"
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.roost = roost
        roost.attach(web)
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:4194/")!))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var roost: RoostController?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let local = url.scheme == "http" && url.host == "127.0.0.1" && url.port == 4194
            if local { decisionHandler(.allow) }
            else {
                if action.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            roost?.dashboardDidFinish(navigation)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            roost?.dashboardDidFail(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            roost?.dashboardDidFail(webView)
        }
    }
}

#endif
