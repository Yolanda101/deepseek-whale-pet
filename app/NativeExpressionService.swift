import AppKit

// A separate login helper keeps the Codex controls available when the independent pet quits.
@main
final class NativeExpressionService: NSObject, NSApplicationDelegate {
    private let companion = Storage()
    private let state: Storage
    private let player: NativeWhaleInteraction
    private var sleeping = false
    private var displaySleeping = false
    private var inactive = false
    private var locked = false
    private var enabled = false

    init(resources: URL) {
        state = companion.nativeExpressions
        let library = AnimationLibrary(resources: resources)
        player = NativeWhaleInteraction(library: library, resources: resources, target: NativeWhaleTarget())
        super.init()
        let overlap = WhaleWindowOverlap(storage: companion)
        player.companionHitTest = { overlap.companionHit(at: $0, library: library) }
        player.onChange = { [weak self] in self?.report() }
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let parentContents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let resources = parentContents.appendingPathComponent("Resources", isDirectory: true)
        let delegate = NativeExpressionService(resources: resources)
        guard let lock = try delegate.state.claim() else { return }
        defer { close(lock) }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(workspaceEvent(_:)), name: name, object: nil)
        }
        let dc = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            dc.addObserver(self, selector: #selector(workspaceEvent(_:)), name: .init(name), object: nil)
        }
        dc.addObserver(self, selector: #selector(readPreferences), name: preferencesNotification, object: companion.commandScope)
        dc.addObserver(self, selector: #selector(statusRequest(_:)), name: commandNotification, object: state.commandScope)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        inactive = session?[kCGSessionOnConsoleKey as String] as? Bool == false
        displaySleeping = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        readPreferences()
        reconcile()
        report()
    }

    @objc private func readPreferences() { player.muted = companion.preferences().muted }

    @objc private func workspaceEvent(_ event: Notification) {
        switch event.name {
        case NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification:
            let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.openai.codex" else { return }
        case NSWorkspace.willSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification: sleeping = false
        case NSWorkspace.screensDidSleepNotification: displaySleeping = true
        case NSWorkspace.screensDidWakeNotification: displaySleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: inactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: inactive = false
        case .init("com.apple.screenIsLocked"): locked = true
        case .init("com.apple.screenIsUnlocked"): locked = false
        default: break
        }
        reconcile()
    }

    private func reconcile() {
        let codexRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .contains { !$0.isTerminated }
        let needed = codexRunning && !sleeping && !displaySleeping && !inactive && !locked
        guard needed != enabled else { return }
        enabled = needed
        if needed { player.start() } else { player.stop() }
        report()
    }

    @objc private func statusRequest(_ note: Notification) {
        guard let message = note.userInfo, message["command"] as? String == "status",
              let request = message["request"] as? String, UUID(uuidString: request) != nil else { return }
        report(request: request)
    }

    private var lastRequest: String?
    private func report(request: String? = nil) {
        if let request { lastRequest = request }
        var info = player.status
        info["running"] = true
        info["watchingCodex"] = enabled
        info["pid"] = ProcessInfo.processInfo.processIdentifier
        if let lastRequest { info["lastCommand"] = ["request": lastRequest, "command": "status", "ok": true] as [String: Any] }
        state.write(info)
    }

    func applicationWillTerminate(_ notification: Notification) {
        player.stop()
        state.write(["running": false, "targetVisible": false])
    }
}
