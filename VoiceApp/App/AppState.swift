import AppKit
import Combine
import OSLog

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isFnPressed = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var hasInputMonitoringPermission = false
    @Published private(set) var statusText = "Click the pill to record"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceApp", category: "AppState")
    private let monitor: FnKeyMonitoring
    private let transcriber = LiveTranscriptionController.shared
    private var permissionPollTimer: Timer?

    private init(monitor: FnKeyMonitoring = FnKeyEventTapMonitor()) {
        self.monitor = monitor

        monitor.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        monitor.onAvailabilityChanged = { [weak self] isAvailable in
            Task { @MainActor in self?.handleAvailabilityChange(isAvailable) }
        }
    }

    func start() {
        FloatingPillController.shared.show()
        isFnPressed = false
        hasInputMonitoringPermission = monitor.hasPermission

        guard hasInputMonitoringPermission else {
            isMonitoring = false
            statusText = "Hold Fn needs Input Monitoring — click the pill to record"
            logger.notice("Fn detection idle: Input Monitoring permission not granted yet")
            return
        }

        startMonitoring()
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        monitor.stop()
        transcriber.cancel()
        FloatingPillController.shared.hide()
        isFnPressed = false
        isMonitoring = false
    }

    func requestPermissionAndRetry() {
        _ = monitor.requestPermission()
        hasInputMonitoringPermission = monitor.hasPermission

        if hasInputMonitoringPermission {
            startMonitoring()
        } else {
            // CGRequestListenEventAccess only opens the prompt; approval lands
            // asynchronously in System Settings. Poll so the tap starts as soon
            // as the checkbox is ticked instead of requiring a relaunch.
            statusText = "Approve \(AppEdition.displayName) under Input Monitoring, then hold Fn"
            beginPollingForPermission()
        }
    }

    func retryMonitoring() {
        hasInputMonitoringPermission = monitor.hasPermission
        startMonitoring()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func beginPollingForPermission() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.monitor.hasPermission else { return }
                timer.invalidate()
                self.permissionPollTimer = nil
                self.hasInputMonitoringPermission = true
                self.startMonitoring()
            }
        }
    }

    private func startMonitoring() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        monitor.stop()

        do {
            try monitor.start()
            isMonitoring = true
            hasInputMonitoringPermission = true
            statusText = "Hold Fn/Globe to talk"
            logger.notice("Fn detection started")
        } catch FnKeyMonitorError.permissionRequired {
            isMonitoring = false
            hasInputMonitoringPermission = false
            statusText = "Input Monitoring permission required"
            logger.error("Fn detection could not start: Input Monitoring permission required")
            beginPollingForPermission()
        } catch {
            isMonitoring = false
            statusText = "Fn detection unavailable"
            logger.error("Fn detection could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ event: FnKeyEvent) {
        switch event {
        case .down where !isFnPressed:
            isFnPressed = true
            transcriber.beginHold()
            logger.notice("Fn down")

        case .up where isFnPressed:
            isFnPressed = false
            transcriber.endHold()
            logger.notice("Fn up")

        case .cancelled where isFnPressed:
            isFnPressed = false
            transcriber.cancel()
            logger.notice("Recording cancelled: Fn was part of a shortcut")

        default:
            break
        }
    }

    private func handleAvailabilityChange(_ isAvailable: Bool) {
        isMonitoring = isAvailable

        if isAvailable {
            statusText = "Hold Fn/Globe to talk"
            logger.notice("Fn event tap restored")
        } else {
            statusText = "Fn detection unavailable"
            if isFnPressed {
                isFnPressed = false
                transcriber.endHold()
                logger.notice("Fn up synthesized because event monitoring stopped")
            }
        }
    }
}
