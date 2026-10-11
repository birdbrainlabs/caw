import Foundation

enum FnKeyEvent: Sendable {
    case down
    case up
    /// Another key was pressed while Fn was held, so this was a shortcut such as
    /// fn+arrow rather than an attempt to dictate.
    case cancelled
}

enum FnKeyMonitorError: LocalizedError {
    case permissionRequired
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Input Monitoring permission is required."
        case .eventTapCreationFailed:
            return "macOS could not create the keyboard event listener."
        }
    }
}

protocol FnKeyMonitoring: AnyObject {
    var onEvent: ((FnKeyEvent) -> Void)? { get set }
    var onAvailabilityChanged: ((Bool) -> Void)? { get set }
    var hasPermission: Bool { get }

    @discardableResult
    func requestPermission() -> Bool
    func start() throws
    func stop()
}
