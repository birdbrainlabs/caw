import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class FloatingPillController: ObservableObject {
    static let shared = FloatingPillController()

    @Published private(set) var insertionError: String?

    private let transcriber = LiveTranscriptionController.shared
    private var panel: FloatingPillPanel?
    private var observations = Set<AnyCancellable>()
    private var dragStartMouseLocation: NSPoint?
    private var dragStartPanelOrigin: NSPoint?

    private init() {}

    func show() {
        if panel == nil {
            let content = FloatingPillView(
                transcriber: transcriber,
                controller: self,
                appState: AppState.shared,
                insertion: TextInsertionController.shared
            )
            let hostingView = NSHostingView(rootView: content)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear

            let panel = FloatingPillPanel(
                contentRect: NSRect(origin: .zero, size: Self.idleSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hostingView
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // macOS approximates a window shadow from the window's shape, which
            // around a circle in a transparent panel renders as a polygonal halo.
            // The shadow is drawn in SwiftUI instead, where it follows the circle.
            panel.hasShadow = false
            // Above full-screen apps and the menu bar: the pill is only useful if
            // it is visible wherever the user happens to be typing.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Takes key focus on a plain click. This was for the review card's
            // text editor (removed 2026-10-02); left as it was so clicking the
            // orb behaves exactly as before.
            panel.becomesKeyOnlyIfNeeded = false
            self.panel = panel

            transcriber.$isRecording
                .combineLatest(transcriber.$isProcessing, transcriber.$rawTranscript)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.deliverDirectlyIfNeeded()
                        self?.updateLayout(animated: true)
                    }
                }
                .store(in: &observations)

            transcriber.$isPreparing
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.updateLayout(animated: true)
                    }
                }
                .store(in: &observations)

            transcriber.$statusText
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.updateLayout(animated: true)
                    }
                }
                .store(in: &observations)

            // Display changes and Dock autohide/size changes both alter the space
            // the pill has to sit in.
            NotificationCenter.default
                .publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.updateLayout(animated: false)
                    }
                }
                .store(in: &observations)
        }

        updateLayout(animated: false)
        #if !BETA
        if RoostController.shared.isDocked { return }
        #endif
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func beginDrag() {
        guard let panel else { return }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartPanelOrigin = panel.frame.origin
    }

    /// Driven from the global mouse location rather than the gesture's own
    /// translation, because the view moves with the panel while it is dragged.
    func continueDrag() {
        guard
            let panel,
            let startMouse = dragStartMouseLocation,
            let startOrigin = dragStartPanelOrigin
        else {
            return
        }

        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(
            NSPoint(
                x: startOrigin.x + (mouse.x - startMouse.x),
                y: startOrigin.y + (mouse.y - startMouse.y)
            )
        )
    }

    func endDrag() {
        defer {
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
        }
        guard let panel, dragStartPanelOrigin != nil else { return }

        // Dropping the orb onto the roost puts the bird home.
        #if !BETA
        if RoostController.enabled, let roostFrame = RoostController.shared.frame,
           roostFrame.intersects(panel.frame) {
            RoostController.shared.dock()
            return
        }
        #endif
        storeAnchor(for: panel.frame)
    }

    /// The roost's drag hands the bird to this panel mid-gesture: the orb
    /// appears under the mouse, undocked, and follows until release.
    #if !BETA
    func pickUpFromRoost() {
        show()
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let size = Self.idleSize
        panel.setFrame(
            NSRect(
                x: mouse.x - size.width / 2,
                y: mouse.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()
        beginDrag()
    }
    #endif

    /// Resizing or restyling the orb, or toggling the roost, must take effect
    /// the instant the menu item is clicked. The first roost shipped without
    /// this send, and settings silently did nothing until an unrelated state
    /// change redrew the view — which made every toggle feel broken.
    func reloadOrb() {
        objectWillChange.send()
        updateLayout(animated: false)
        #if !BETA
        RoostController.shared.refresh()
        #endif
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.screenDefaultsKey)
        updateLayout(animated: true)
    }

    func beginPressToTalk() {
        insertionError = nil
        transcriber.beginHold(fromKey: false)
    }

    func endPressToTalk() {
        transcriber.endHold()
    }

    /// Whether Punctuate runs on the way to the caret. OFF by default since
    /// 2026-09-17: measured on the owner's machine it held every paste for
    /// 2.7–8.3s and changed 6% of dictations, and the new engine punctuates as
    /// it hears. Off is the plain deterministic cleaner, which is instant. The
    /// key is new so the old default-on setting cannot carry over.
    static var punctuatesAutomatically: Bool {
        UserDefaults.standard.bool(forKey: "PunctuateBeforePaste")
    }

    /// Set while a direct insert is being delivered, so the several published
    /// changes that arrive as a transcript settles cannot each deliver it.
    private var isDelivering = false

    /// Deliver the finished transcript to wherever the caret is, once.
    private func deliverDirectlyIfNeeded() {
        guard !isDelivering else { return }
        guard transcriber.hasTranscript,
              !transcriber.isRecording,
              !transcriber.isProcessing,
              !transcriber.isPreparing
        else {
            return
        }

        #if !BETA
        if transcriber.targetsHome {
            let text = transcriber.configuredCleaner.clean(transcriber.rawTranscript)
            isDelivering = true
            Task { @MainActor in
                defer { self.isDelivering = false }
                if await RoostController.shared.receiveDictation(text) {
                    self.transcriber.clearTranscript()
                } else {
                    self.insertionError = "Click a text box in Home and try again. Your transcript is still available."
                }
            }
            return
        }
        #endif
        if transcriber.targetsSetup {
            SetupWindow.shared.receiveDictation(transcriber.configuredCleaner.clean(transcriber.rawTranscript))
            transcriber.clearTranscript()
            return
        }
        if transcriber.targetsCrumbChat {
            if #available(macOS 26.0, *) {
                let text = transcriber.configuredCleaner.clean(transcriber.rawTranscript)
                CrumbChatModel.shared.receiveDictation(text)
                transcriber.clearTranscript()
                return
            }
        }
        let raw = transcriber.rawTranscript
        let cleaned = transcriber.configuredCleaner.clean(raw)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isDelivering = true
        insertionError = nil

        // macOS naps a background app the moment its microphone closes — which
        // for this app is the exact moment it has work to do. Declaring the
        // delivery as user-initiated forbids the nap until the paste completes.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Delivering dictated text"
        )

        Task { @MainActor [weak self] in
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                self?.isDelivering = false
            }
            guard let self else { return }

            // Punctuation, before it lands rather than on a button the user has
            // to find — there is no card to put a button on any more, and asking
            // for full stops is not a decision anybody wants to make per message.
            //
            // The model is used for exactly what it is dependable at and nothing
            // else, and it can only ever improve the text: every failure path
            // here falls through to the cleaned transcript, so a slow, refused
            // or run-away model costs the words nothing. Short transcripts skip
            // it entirely inside `polish`.
            var text = cleaned
            if Self.punctuatesAutomatically, TranscriptPolisher.shared.isAvailable {
                if case .success(let polished) = await TranscriptPolisher.shared.polish(cleaned, style: .punctuate),
                   !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = polished
                }
            }

            switch await TextInsertionController.shared.insertAtCursor(text) {
            case .success:
                // Cleared even when the text is only being held: it is on the
                // clipboard and the hold will place it, and leaving it here would
                // have the next published change try to deliver it all over again.
                // `cleaned` and `sent` differ again whenever Punctuate changed
                // something, which is the only correction signal left now that
                // editing happens in the destination's own text box where this
                // app cannot see it.
                TrainingCorpus.shared.record(raw: raw, cleaned: cleaned, sent: text, destination: "(at cursor)")
                self.transcriber.clearTranscript()
            case .failure(let error):
                // The transcript is deliberately left alone so nothing is lost,
                // and it is already on the clipboard, so ⌘V still works.
                self.insertionError = error.localizedDescription
                self.transcriber.announce(error.localizedDescription)
            }
        }
    }

    func dismissStatus() {
        insertionError = nil
        transcriber.dismissStatus()
    }

    private func updateLayout(animated: Bool) {
        guard let panel else { return }

        // Self-heal a drag that never ended. Removing the roost's orb view
        // mid-gesture cancels the gesture without its onEnded — which left the
        // panel permanently "being dragged" and therefore permanently unable to
        // resize: the panel stayed squeezed into an orb-sized strip.
        // If no mouse button is down, no drag is happening, whatever the state
        // claims.
        if dragStartPanelOrigin != nil, NSEvent.pressedMouseButtons & 1 == 0 {
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
        }

        let size: NSSize
        if transcriber.isRecording {
            size = Self.listeningSize
        } else if transcriber.isProcessing || transcriber.isPreparing {
            size = Self.processingSize
        } else if transcriber.statusKind == .warning {
            size = Self.messageSize
        } else {
            size = Self.idleSize
        }

        // While the orb is docked, the roost draws it and this panel stays away —
        // EXCEPT for status messages, which always surface.
        let surfaces = transcriber.statusKind == .warning
        #if !BETA
        if RoostController.enabled, RoostController.shared.isDocked, !surfaces {
            panel.orderOut(nil)
            return
        }
        #endif
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        guard dragStartPanelOrigin == nil else { return }

        guard let screen = targetScreen else { return }

        let frame = NSRect(origin: origin(for: size, on: screen), size: size)

        // Never animated. An animated resize is what made the orb appear to drift
        // and swell on its way between states; it should look nailed to the spot.
        panel.setFrame(frame, display: true)
    }

    private static let anchorDefaultsKey = "FloatingPillAnchor"
    private static let screenDefaultsKey = "FloatingPillScreen"

    /// The pill stays on the display the user put it on. It used to follow the
    /// mouse between screens, which meant looking for it where you left it and
    /// finding it somewhere else.
    private var targetScreen: NSScreen? {
        let storedNumber = UserDefaults.standard.integer(forKey: Self.screenDefaultsKey)

        if storedNumber != 0, let screen = NSScreen.screens.first(where: { $0.displayNumber == storedNumber }) {
            return screen
        }

        // Nothing chosen yet, or that display is no longer attached.
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// The chosen position is stored as a fraction of the screen's usable area, so
    /// it survives resolution changes and lands in the same relative spot if the
    /// pill is later moved to a differently sized display.
    private var storedAnchor: CGPoint? {
        guard
            let values = UserDefaults.standard.array(forKey: Self.anchorDefaultsKey) as? [Double],
            values.count == 2
        else {
            return nil
        }
        return CGPoint(x: values[0], y: values[1])
    }

    private func storeAnchor(for frame: NSRect) {
        // Every panel shares the orb's bottom-right corner, so the orb's rect can
        // be recovered from any of them — including a warning.
        let orbRect = NSRect(
            x: frame.maxX - Self.orbSize.width,
            y: frame.minY,
            width: Self.orbSize.width,
            height: Self.orbSize.height
        )
        let center = NSPoint(x: orbRect.midX, y: orbRect.midY)
        let screen = NSScreen.screens.first(where: { NSPointInRect(center, $0.frame) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(orbRect) })
            ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return
        }

        let anchor = [
            Double((center.x - visibleFrame.minX) / visibleFrame.width),
            Double((center.y - visibleFrame.minY) / visibleFrame.height),
        ]
        UserDefaults.standard.set(anchor, forKey: Self.anchorDefaultsKey)

        // Dragging the pill onto a display is how that display gets chosen.
        if let displayNumber = screen?.displayNumber {
            UserDefaults.standard.set(displayNumber, forKey: Self.screenDefaultsKey)
        }
    }

    /// The orb's rectangle is the anchor for every state. Larger panels — a
    /// warning — share its bottom-right corner and grow up and to
    /// the left, so the orb itself never shifts by a single pixel. Centring every
    /// state on the anchor, as this did before, moved the orb whenever the panel
    /// changed size.
    private func origin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let bottomInset = Self.bottomInset(for: screen)
        let edgeInset: CGFloat = 8

        var orbOrigin: NSPoint
        if let anchor = storedAnchor {
            orbOrigin = NSPoint(
                x: visibleFrame.minX + anchor.x * visibleFrame.width - Self.orbSize.width / 2,
                y: visibleFrame.minY + anchor.y * visibleFrame.height - Self.orbSize.height / 2
            )
        } else {
            orbOrigin = NSPoint(
                x: visibleFrame.maxX - Self.orbSize.width - edgeInset,
                y: visibleFrame.minY + bottomInset
            )
        }

        let floor = storedAnchor == nil ? visibleFrame.minY + bottomInset : screen.frame.minY + edgeInset
        orbOrigin.x = min(max(orbOrigin.x, visibleFrame.minX + edgeInset), visibleFrame.maxX - Self.orbSize.width - edgeInset)
        orbOrigin.y = min(max(orbOrigin.y, floor), visibleFrame.maxY - Self.orbSize.height - edgeInset)

        guard size != Self.orbSize else { return orbOrigin }

        var origin = NSPoint(x: orbOrigin.maxXOffset(by: Self.orbSize.width) - size.width, y: orbOrigin.y)
        origin.x = min(max(origin.x, visibleFrame.minX + edgeInset), visibleFrame.maxX - size.width - edgeInset)
        origin.y = min(max(origin.y, floor), visibleFrame.maxY - size.height - edgeInset)
        return origin
    }

    /// A Dock parked at the bottom is already excluded from `visibleFrame`, so the
    /// pill can hug that edge. An auto-hidden Dock is not excluded — `visibleFrame`
    /// runs to the bottom of the screen and the Dock slides in on top of the pill.
    /// In that case reserve the height the Dock will occupy once it appears.
    private static func bottomInset(for screen: NSScreen) -> CGFloat {
        let restingInset: CGFloat = 4
        let bottomIsReserved = screen.visibleFrame.minY > screen.frame.minY + 1
        guard !bottomIsReserved else { return restingInset }

        let dock = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = dock?.object(forKey: "tilesize") as? Double ?? 48
        var dockHeight = CGFloat(tileSize)

        if dock?.bool(forKey: "magnification") == true {
            let largeSize = dock?.object(forKey: "largesize") as? Double ?? tileSize
            dockHeight = min(CGFloat(largeSize), 96)
        }

        return dockHeight + 30
    }

    /// The visible diameter of the orb. Panel sizes add the 4pt padding the view
    /// draws inside, which is why a 36pt panel was only ever a 28pt circle.
    /// 40 was the orange circle's size before any of this; 28 was the resting orb.
    /// Change this one number to resize every state together.
    /// Any value works — the window around it is derived from the geometry rather
    /// than stepped, so 48, 103 and 200 are all equally valid.
    static var orbDiameter: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "OrbDiameter")
        return orbStyleIsMascot ? max(72, CGFloat(stored)) : (stored > 0 ? CGFloat(stored) : 48)
    }

    /// "egg" or the default raven blue. The egg is stage zero of the bird.
    /// The 3D mascot, Crumb, has his page in Resources/Crumb.
    static var mascotPage: String? {
        switch UserDefaults.standard.string(forKey: "OrbStyle") {
        case "crumb": return "index.html"
        default: return nil
        }
    }

    static var orbStyleIsMascot: Bool { mascotPage != nil }

    static var orbStyleIsEgg: Bool {
        UserDefaults.standard.string(forKey: "OrbStyle") == "egg"
    }


    /// How far the shape can travel past its radius at full voice — the sum of
    /// the three wave amplitudes.
    static let orbTravel: CGFloat = 1.354
    static var orbGlow: CGFloat { orbDiameter * 0.28 }

    /// The drawing area: the whole window less the view's own padding.
    static var orbCanvasSide: CGFloat { orbSize.width - 8 }

    /// The bird is drawn at the size it appeared inside the old disc; the ring
    /// while listening circumscribes it.
    static let birdHeight: CGFloat = 48

    /// Continuous-corner radius for the square orb, in the macOS icon idiom.
    static let orbCorner: CGFloat = orbDiameter * 0.24

    /// The window has to hold the orb, the distance the shape travels at full
    /// voice, AND the full spread of the glow — and a Core Graphics shadow with
    /// blur r spreads roughly 2.5r, not r. Sizing it for r alone clipped the halo
    /// against the canvas edge, which read as a square cutting the circle.
    static var orbSize: NSSize {
        let travelMargin = orbDiameter * (orbTravel - 1) / 2
        let glowMargin = orbGlow * 2.5
        let side = orbDiameter + (travelMargin + glowMargin) * 2 + 8
        return NSSize(width: side, height: side)
    }
    private static var idleSize: NSSize { orbSize }
    private static let messageSize = NSSize(width: 380, height: 58)
    private static var listeningSize: NSSize { orbSize }
    private static var processingSize: NSSize { orbSize }

    private var displaysDetailedStatus: Bool {
        transcriber.statusKind != .ready
    }
}

private extension NSPoint {
    func maxXOffset(by width: CGFloat) -> CGFloat { x + width }
}

private extension NSScreen {
    /// Stable per-display identifier, so the chosen screen survives relaunches.
    var displayNumber: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}

/// Drawn through Core Graphics rather than SwiftUI shapes, for two things the
/// SwiftUI equivalents cannot do: a radial gradient with an offset inner circle
/// and a centred outer one, which is what lights it like a sphere; and a shadow
/// cast by the shape itself rather than by the view's rectangle, which is what
/// put a square box around the first attempt.
struct OrbCanvas: View {
    let diameter: CGFloat
    let talking: Bool
    let level: Double
    let time: Double
    var egg: Bool = FloatingPillController.orbStyleIsEgg

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            context.withCGContext { cg in
                Self.draw(in: cg, box: size, diameter: diameter, talking: talking, level: level, time: time, egg: egg)
            }
        }
    }

    static func draw(in cg: CGContext, box: CGSize, diameter: CGFloat, talking: Bool, level: Double, time: Double, egg: Bool) {
        let centre = CGPoint(x: box.width / 2, y: box.height / 2)
        let base = diameter / 2
        let glow = diameter * 0.28

        let path = CGMutablePath()
        let points = 120

        for index in 0...points {
            let angle = Double(index) / Double(points) * .pi * 2
            var offset = 0.0

            if talking {
                let layer1 = sin(angle * 4 + time * 2) * base * 0.077
                let layer2 = cos(angle * 7 - time * 3) * base * 0.062
                let voice = sin(angle * 5 + time * 6) * (level * base * 0.215)
                offset = layer1 + layer2 + voice
            }

            var radius = base + offset
            var yStretch = 1.0
            if egg {
                // An egg is a circle that is wider below its middle than above
                // it, and a little taller than it is wide. The Canvas draws with
                // y increasing downward, so positive sin(angle) is the fat end.
                radius *= 1 + 0.09 * sin(angle)
                yStretch = 1.08
            }
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius * yStretch)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()

        // The egg's yolk drifts more than the raven orb's highlight, because the
        // whole joke of the egg is the yellow centre sloshing while it talks. At
        // rest the yolk sits dead centre — a still fried egg, not a lit sphere.
        let shift = egg
            ? (talking ? base * 0.29 : 0)
            : base * (talking ? 0.231 : 0.115)
        let inner = CGPoint(x: centre.x + cos(time * 0.8) * shift, y: centre.y + sin(time * 0.8) * shift)

        func colour(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        // The near-black stops from the web version are gone: they exist to blend
        // into a dark page, and on a transparent panel they only muddy the edge.
        //
        // The egg is a FRIED egg and reads centre-outward: bright yellow yolk in
        // the middle, white all around it. The first version had this exactly
        // inverted — white-hot centre shading to gold edges — and looked like a
        // lamp, not an egg. Identical palette in every state; only the yolk's
        // position changes, and only while talking.
        let stops: [CGFloat]
        let colours: [CGColor]
        if egg {
            stops = [0, 0.30, 0.52, 0.78, 1]
            colours = [
                colour(0xffc61a), colour(0xffd23d), colour(0xfff2c9),
                colour(0xffffff), colour(0xffffff),
            ]
        } else {
            stops = talking ? [0, 0.22, 0.52, 0.82, 1] : [0, 0.32, 0.72, 1]
            colours = talking
                ? [colour(0xffffff), colour(0x7dd3fc), colour(0x38bdf8), colour(0x4f7cf7), colour(0x4f46e5)]
                : [colour(0xe6f4ff), colour(0x60a5fa), colour(0x3b82f6), colour(0x2563eb)]
        }

        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colours as CFArray, locations: stops) else { return }

        // The glow is cast by filling the path itself. Wrapping this in a
        // transparency layer, as the first version did, makes Core Graphics shadow
        // the LAYER — whose bounds are the whole canvas — which draws a square.
        cg.saveGState()
        if egg {
            // A soft white halo, the same in every state — the egg does not
            // light up, it just sits there being an egg.
            cg.setShadow(offset: .zero, blur: glow,
                         color: CGColor(srgbRed: 1.0, green: 0.98, blue: 0.9, alpha: 0.55))
            cg.addPath(path)
            cg.setFillColor(colour(0xffffff))
        } else {
            cg.setShadow(offset: .zero, blur: glow,
                         color: CGColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: talking ? 0.85 : 0.6))
            cg.addPath(path)
            cg.setFillColor(colour(0x3b82f6))
        }
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        // A bigger start radius on the egg turns the highlight into a yolk.
        cg.drawRadialGradient(gradient, startCenter: inner, startRadius: base * (egg ? 0.28 : 0.077),
                              endCenter: centre, endRadius: base * 1.154,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(path)
        if egg {
            cg.setStrokeColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.9, alpha: 0.8))
            cg.setShadow(offset: .zero, blur: glow * 0.5,
                         color: CGColor(srgbRed: 1.0, green: 0.97, blue: 0.88, alpha: 0.7))
        } else {
            cg.setStrokeColor(CGColor(srgbRed: 0.404, green: 0.925, blue: 0.910, alpha: talking ? 0.95 : 0.75))
            cg.setShadow(offset: .zero, blur: glow * 0.5,
                         color: CGColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 0.9))
        }
        cg.setLineWidth(max(1, base * 0.022))
        cg.strokePath()
        cg.restoreGState()
    }
}

private final class FloatingPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    #if !BETA
    @objc private func sendHome() { RoostController.shared.dock() }
    @objc private func openHome() { RoostController.shared.showWindow() }
    #endif

    /// Claim the keyboard on any click, BEFORE the event routes to the view.
    /// Written for the review card's editor (the card was removed 2026-10-02);
    /// kept unchanged so clicking the orb behaves as it did.
    ///
    /// The first attempt at this was a SwiftUI tap gesture across the card,
    /// which fixed the missing caret but made clicks mushy — gesture
    /// recognizers over AppKit-hosted text views eat or delay first clicks.
    /// Doing it here costs nothing: the event proceeds untouched, the window
    /// is simply key by the time it lands.
    override func sendEvent(_ event: NSEvent) {
        #if !BETA
        if event.type == .rightMouseDown, RoostController.enabled {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Go home", action: #selector(sendHome), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let openItem = NSMenuItem(title: "Open Home", action: #selector(openHome), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
            if let view = contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
            return
        }
        #endif
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// Drag anywhere on the pill to move it; a press that never travels is a click.
private struct PillInteraction: ViewModifier {
    let controller: FloatingPillController
    let onClick: (() -> Void)?

    @State private var isDragging = false

    private static let dragThreshold: CGFloat = 4

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        guard
                            abs(value.translation.width) > Self.dragThreshold
                                || abs(value.translation.height) > Self.dragThreshold
                        else {
                            return
                        }
                        isDragging = true
                        controller.beginDrag()
                    }
                    controller.continueDrag()
                }
                .onEnded { _ in
                    if isDragging {
                        isDragging = false
                        controller.endDrag()
                    } else {
                        onClick?()
                    }
                }
        )
    }
}

private extension View {
    func pillInteraction(_ controller: FloatingPillController, onClick: (() -> Void)? = nil) -> some View {
        modifier(PillInteraction(controller: controller, onClick: onClick))
    }
}

/// The ring owns its own state so the animation restarts each time recording
/// begins. Driving it from a parent flag that flips once on first appearance
/// leaves the ring on screen but frozen.
private struct PulsingRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            .scaleEffect(expanded ? 1.0 : 0.82)
            .opacity(expanded ? 0.0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// Travels once around the bird to acknowledge a send, then stops with the status.
private struct ConfirmingRing: View {
    let lineWidth: CGFloat
    var cornerRadius: CGFloat = 0
    @State private var spinning = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: 0.28)
            .stroke(Color(red: 0.914, green: 0.412, blue: 0.310), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

private struct FloatingPillView: View {
    @ObservedObject var transcriber: LiveTranscriptionController
    @ObservedObject var controller: FloatingPillController
    @ObservedObject var appState: AppState
    @ObservedObject var insertion: TextInsertionController

    var body: some View {
        Group {
            if showsMessage {
                messagePill
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1) }
            } else {
                orb
            }
        }
        .padding(4)
    }

    /// The orb. A true circle at rest — the breathing amplitude is zero, so there
    /// is nothing to animate and nothing to redraw. It only moves while you are
    /// speaking, and it moves to the real microphone level.
    private var orb: some View {
        Group {
            if let page = FloatingPillController.mascotPage {
                CrumbMascotView(page: page)
                    .id(page)
            } else if transcriber.isRecording {
                TimelineView(.animation) { timeline in
                    OrbCanvas(
                        diameter: FloatingPillController.orbDiameter,
                        talking: true,
                        level: Double(transcriber.inputLevel),
                        time: timeline.date.timeIntervalSinceReferenceDate * 2.1
                    )
                }
            } else {
                OrbCanvas(diameter: FloatingPillController.orbDiameter, talking: false, level: 0, time: 0)
            }
        }
        .overlay {
            if transcriber.isProcessing || transcriber.isPreparing {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        // Words finished and waiting for somewhere to go. Deliberately not a
        // message and not a pill: nothing to read, nothing to click, and nothing
        // that can take the caret — taking the caret is the entire problem this
        // exists to avoid. It simply looks different until the text lands.
        .overlay {
            if insertion.isHoldingText {
                Circle()
                    .strokeBorder(Self.orbTint, lineWidth: 2.5)
                    .padding(2)
                    .transition(.opacity)
            }
        }
        // Fixed, so it can never inflate to a warning's width mid-resize —
        // but sized to the ORB'S WINDOW, not the orb. Pinning it to the diameter
        // clipped the drawing at the circle's own edge, cutting the glow off in a
        // straight line on all four sides.
        .frame(width: FloatingPillController.orbCanvasSide, height: FloatingPillController.orbCanvasSide)
        .contentShape(Circle())
        .pillInteraction(controller) {
            if transcriber.isRecording {
                controller.endPressToTalk()
            } else if !transcriber.isProcessing && !transcriber.isPreparing {
                controller.beginPressToTalk()
            }
        }
        .accessibilityLabel(orbAccessibilityLabel)
    }

    private var isAnimating: Bool {
        transcriber.isRecording || transcriber.isProcessing || transcriber.isPreparing
    }

    private func blob(at seconds: TimeInterval) -> some View {
        let talking = transcriber.isRecording
        let level = Double(transcriber.inputLevel)

        return Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let base = min(size.width, size.height) / 2 * 0.82
            let time = seconds * (talking ? 2.4 : 0.9)

            var path = Path()
            let points = 96

            for index in 0...points {
                let angle = Double(index) / Double(points) * .pi * 2
                let offset: Double

                if talking {
                    let noise1 = sin(angle * 4 + time * 2) * base * 0.085
                    let noise2 = cos(angle * 7 - time * 3) * base * 0.055
                    let voice = sin(angle * 3 + time * 5) * base * 0.16 * level
                    offset = noise1 + noise2 + voice
                } else {
                    offset = 0
                }

                let radius = base + offset
                let point = CGPoint(
                    x: centre.x + cos(angle) * radius,
                    y: centre.y + sin(angle) * radius
                )
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }

            path.closeSubpath()

            // The highlight orbits while talking, which is what stops it reading
            // as a flat disc; at rest it sits still, up and to the left.
            let highlight = talking
                ? CGPoint(x: centre.x - base * 0.3 * cos(time), y: centre.y - base * 0.3 * sin(time))
                : CGPoint(x: centre.x - base * 0.28, y: centre.y - base * 0.28)

            context.fill(
                path,
                with: .radialGradient(
                    talking ? Self.talkingGradient : Self.standbyGradient,
                    center: highlight,
                    startRadius: base * 0.05,
                    endRadius: base * 1.15
                )
            )
        }
    }

    @ViewBuilder
    private var orbGlyph: some View {
        if transcriber.isProcessing || transcriber.isPreparing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .tint(.white)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: FloatingPillController.orbDiameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: transcriber.isRecording)
        }
    }

    /// Loaded once; the bundle lookup is far too slow to repeat on every redraw.
    private static let birdImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "caw-raven", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// #2D3038 — dark, so the sticker's white outline carries the edge and no ring
    /// is needed at rest. One constant; change it to retune the disc.
    private static let discColour = Color(red: 0.176, green: 0.188, blue: 0.220)

    private var orbAccessibilityLabel: String {
        if insertion.isHoldingText {
            return "Your words are waiting. Click into a text box and they will go in."
        }
        if transcriber.isRecording { return "Listening. Click to stop recording, or drag to move." }
        if transcriber.isProcessing { return "Finishing the transcript. Drag to move." }
        if transcriber.isPreparing { return "Setting up permissions. Drag to move." }
        return appState.isMonitoring
            ? "Hold Fn to talk, click to start recording, or drag to move."
            : "Click to start recording, or drag to move."
    }

    /// Only a warning becomes the wide pill. A confirmation — "sent", "copied" —
    /// shows as a ring travelling around the bird, so the thing on screen keeps its
    /// shape and just acknowledges you.
    private var showsMessage: Bool {
        transcriber.statusKind == .warning
            && !transcriber.isRecording && !transcriber.isProcessing && !transcriber.isPreparing
    }

    private var messagePill: some View {
        HStack(spacing: 8) {
            Image(systemName: transcriber.statusKind == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(transcriber.statusKind == .warning ? Self.orbTint : Color.secondary)
            Text(transcriber.statusText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule())
        .pillInteraction(controller) {
            controller.dismissStatus()
        }
    }

    /// #E8836D — measured from the beak in the artwork, so nothing in the app can
    /// disagree with the logo.
    /// #E9694F — averaged from the open beak in the artwork.
    private static let orbTint = Color(red: 0.914, green: 0.412, blue: 0.310)

    /// Royal blue at rest, blooming to white and cyan while listening.
    private static let standbyGradient = Gradient(colors: [
        Color(red: 0.376, green: 0.647, blue: 0.980),
        Color(red: 0.145, green: 0.388, blue: 0.922),
        Color(red: 0.114, green: 0.306, blue: 0.847),
        Color(red: 0.059, green: 0.090, blue: 0.165),
    ])

    private static let talkingGradient = Gradient(colors: [
        .white,
        Color(red: 0.220, green: 0.741, blue: 0.973),
        Color(red: 0.145, green: 0.388, blue: 0.922),
        Color(red: 0.263, green: 0.220, blue: 0.792),
        Color(red: 0.035, green: 0.051, blue: 0.086),
    ])

    private static let glow = Color(red: 0.145, green: 0.388, blue: 0.922)

    private var displaysDetailedStatus: Bool {
        transcriber.statusKind != .ready
    }
}

/// The mascot receives only state, level and a delivery counter; no audio or text.
struct CrumbMascotView: View {
    #if !BETA
    @ObservedObject private var nest = RoostController.shared
    private var nestThinking: Bool { nest.dashboardThinking }
    private var nestDelivery: Int { nest.dashboardDelivery + nest.dictationDelivery }
    #else
    private var nestThinking: Bool { false }
    private var nestDelivery: Int { 0 }
    #endif
    @ObservedObject private var chatActivity = CrumbChatActivity.shared
    /// Which character's page in Resources/Crumb: "index.html" is Crumb.
    var page = "index.html"
    @ObservedObject private var transcriber = LiveTranscriptionController.shared
    @ObservedObject private var insertion = TextInsertionController.shared
    /// Crumb only animates while something is happening — recording,
    /// thinking, holding text. Otherwise he is a still picture: redrawing a
    /// 3D scene 30 times a second all day was most of the app's idle CPU.
    /// The page still plays its short celebration
    /// after a delivery before going still.
    /// False while this copy of him is hidden (the Home window's copy while
    /// he is out on the desktop), so a hidden copy never draws.
    var shown = true
    private var active: Bool {
        shown && (transcriber.isRecording || transcriber.isProcessing || transcriber.isPreparing
            || chatActivity.thinking || nestThinking || insertion.isHoldingText)
    }
    var body: some View {
        CrumbWebView(page: page, active: active, recording: transcriber.isRecording,
                     processing: transcriber.isProcessing || transcriber.isPreparing || chatActivity.thinking || nestThinking,
                     waiting: insertion.isHoldingText,
                     level: Double(transcriber.inputLevel), delivery: insertion.crumbDeliveryID + nestDelivery)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CrumbWebView: NSViewRepresentable {
    var page: String
    var active: Bool
    var recording: Bool
    var processing: Bool
    var waiting: Bool
    var level: Double
    var delivery: Int

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = CrumbPassiveWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("Crumb"),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(page).path) {
            view.loadFileURL(directory.appendingPathComponent(page), allowingReadAccessTo: directory)
        }
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.payload = ["active": active, "recording": recording, "processing": processing,
            "waiting": waiting, "level": level.isFinite ? min(1, max(0, level)) : 0,
            "delivery": delivery, "gentle": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        view.stopLoading()
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var payload: [String: Any] = [:]
        var timer: Timer?
        var ready = false
        var sending = false
        var lastJSON = ""
        /// 30 updates a second while Crumb is awake; four while he is still,
        /// which is enough to notice the Fn press that wakes him.
        func start() { schedule(interval: 1.0 / 4) }
        private var interval: TimeInterval = 0
        private func schedule(interval: TimeInterval) {
            guard interval != self.interval else { return }
            self.interval = interval
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.send()
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastJSON = ""
            send()
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.reload()
        }
        func send() {
            schedule(interval: (payload["active"] as? Bool ?? false) ? 1.0 / 30 : 1.0 / 4)
            guard ready, !sending, let webView else { return }
            var value = payload
            value["active"] = (payload["active"] as? Bool ?? true) && webView.window?.isVisible == true
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8), json != lastJSON else { return }
            sending = true
            webView.evaluateJavaScript("window.updateCrumb(\(json))") { [weak self] _, error in
                self?.sending = false
                if error == nil { self?.lastJSON = json }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}

private final class CrumbPassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
