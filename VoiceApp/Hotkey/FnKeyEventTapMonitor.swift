import AppKit
import CoreGraphics
import OSLog

final class FnKeyEventTapMonitor: FnKeyMonitoring {
    var onEvent: ((FnKeyEvent) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?

    var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "FnKeyMonitor")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnDown = false
    private var holdWasCancelled = false
    private var workspaceObservers: [NSObjectProtocol] = []

    deinit {
        stop()
    }

    @discardableResult
    func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    func start() throws {
        guard eventTap == nil else { return }
        guard hasPermission else { throw FnKeyMonitorError.permissionRequired }

        // Modifier changes, plus the bare fact that some other key was pressed.
        // The keycode is never read: this needs to know THAT a key happened, so a
        // shortcut like fn+arrow can cancel a recording, never WHICH key it was.
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
            | CGEventMask(1) << CGEventType.keyDown.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: context
        ) else {
            throw FnKeyMonitorError.eventTapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw FnKeyMonitorError.eventTapCreationFailed
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        installWorkspaceObservers()
    }

    func stop() {
        removeWorkspaceObservers()

        if isFnDown {
            isFnDown = false
            onEvent?(.up)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }

        let monitor = Unmanaged<FnKeyEventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverEventTap()
            return
        }

        if type == .keyDown {
            guard isFnDown, !holdWasCancelled else { return }
            holdWasCancelled = true
            logger.notice("Another key was pressed while Fn was held; cancelling")
            onEvent?(.cancelled)
            return
        }

        guard type == .flagsChanged else { return }

        let fnIsDown = event.flags.contains(.maskSecondaryFn)
        guard fnIsDown != isFnDown else { return }

        updateFnState(fnIsDown)
    }

    private func recoverEventTap() {
        guard let eventTap else {
            onAvailabilityChanged?(false)
            return
        }

        logger.warning("Fn event tap was disabled by macOS; attempting to restore it")
        CGEvent.tapEnable(tap: eventTap, enable: true)
        let restored = CGEvent.tapIsEnabled(tap: eventTap)
        onAvailabilityChanged?(restored)

        // Events that happened while the tap was off are gone. If the lost one
        // was the Fn release, `isFnDown` stays true and every later press is
        // filtered as "no change" — so ask the keyboard where Fn really is.
        let fnIsReallyDown = restored
            && CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        if isFnDown != fnIsReallyDown {
            updateFnState(fnIsReallyDown)
        }
    }

    private func updateFnState(_ isDown: Bool) {
        guard isDown != isFnDown else { return }
        isFnDown = isDown

        guard isDown else {
            // A cancelled hold has already been dealt with; releasing Fn after
            // fn+arrow must not deliver a recording nobody asked for.
            if holdWasCancelled {
                holdWasCancelled = false
                return
            }
            onEvent?(.up)
            return
        }

        holdWasCancelled = false
        onEvent?(.down)
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.isFnDown {
                    self.updateFnState(false)
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.recoverEventTap()
            }
        )
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }
}
