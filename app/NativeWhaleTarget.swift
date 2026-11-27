import Foundation

/// The AppKit frame of the selected whale's live Codex mascot, in global screen points.
/// Call from the main thread alongside the AppKit hover panel.
final class NativeWhaleTarget {
    private static let avatarIDs: Set<String> = ["custom:deepseek-q-whale"]
    private let locator: NativePetLocator
    private var lastProbe: TimeInterval?
    private var lastLocation: NativePetLocation?

    init(codexHome: URL = ActivityMonitor.defaultCodexHome) {
        locator = NativePetLocator(codexHome: codexHome)
    }

    func current() -> NativePetLocation? {
        let now = ProcessInfo.processInfo.systemUptime
        // The panel's animation timer may run at 60 Hz. Only a visible target
        // needs rapid geometry updates while the user is dragging the mascot.
        let interval = lastLocation == nil ? 0.18 : 0.055
        if let previous = lastProbe, now - previous < interval { return lastLocation }
        lastProbe = now
        lastLocation = locator.current(matchingAvatarIDs: Self.avatarIDs)
        return lastLocation
    }
}
