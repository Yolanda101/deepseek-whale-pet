import AppKit
import CoreGraphics
import Foundation

private let appName = "DeepSeek 大肥鱼"

final class WhalePet: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let storage: Storage
    private var preferences: Preferences
    private let library: AnimationLibrary
    private let nativeSize = NativePetSizeReader()
    private let monitor = ActivityMonitor()
    private let stage: PetStage
    private let resources: URL
    private let version: String
    private let unattendedTest: Bool
    private var statusItem: NSStatusItem?
    private var maintenanceTimer: Timer?
    private var active: Bool?
    private var displaySuspended = false
    private var computerSuspended = false
    private var sessionSuspended = false
    private var sessionLocked = false
    private var running = false
    private var lastCommand: [String: Any]?

    init(storage: Storage, library: AnimationLibrary, resources: URL, version: String) {
        self.storage = storage
        var preferences = storage.preferences()
        if preferences.skin == "model" {
            preferences.skin = Skin.figurine.rawValue
            storage.save(preferences)
        }
        self.preferences = preferences
        self.library = library
        self.resources = resources
        self.version = version
        let env = ProcessInfo.processInfo.environment
        unattendedTest = env["WHALE_PET_UI_TEST"] == "1" && env["WHALE_PET_DATA_DIR"] != nil
        let skin = preferences.skin.flatMap(Skin.init(rawValue:)).flatMap {
            library.skins.contains($0) ? $0 : nil
        } ?? library.skins[0]
        let width = preferences.independentWidth.map(NativePetSize.clamp) ?? nativeSize.width()
        let center = preferences.position.map { NSPoint(x: $0.x, y: $0.y) }
        stage = PetStage(library: library, resources: resources, skin: skin, width: width, center: center,
                         unattendedTest: unattendedTest)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        running = true
        stage.roaming = preferences.roaming
        stage.muted = preferences.muted
        stage.onChange = { [weak self] in self?.writeStatus() }
        let overlap = WhaleWindowOverlap(storage: storage.nativeExpressions)
        let mask = AnimationFrame(resources.appendingPathComponent("NativeMask.png"))?.alpha
        stage.allowHoverAtPoint = { [weak self] point in
            guard let self, let mask else { return true }
            return !overlap.nativeCovers(point, companionWindow: self.stage.windowNumber, mask: mask)
        }
        stage.onMoved = { [weak self] point in
            guard let self else { return }
            self.preferences.position = .init(x: point.x, y: point.y)
            self.storage.save(self.preferences)
        }
        stage.contextMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }

        if !unattendedTest {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "大肥鱼"
            item.button?.toolTip = appName
            let menu = makeMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(systemDidChange(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidChange(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let events = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            events.addObserver(self, selector: #selector(systemDidChange(_:)), name: .init(name), object: nil)
        }
        events.addObserver(self, selector: #selector(receive(_:)), name: commandNotification,
                           object: storage.commandScope)

        monitor.start { [weak self] active in
            guard let self else { return }
            let finished = self.active == true && !active
            self.active = active
            self.stage.setWorking(active)
            if finished && self.preferences.completionVoice { self.stage.notifyFinished() }
            self.writeStatus()
        }
        maintain()
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.maintain() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
        writeStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setHidden(false)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        maintenanceTimer?.invalidate()
        running = false
        stage.setVisible(false)
        writeStatus()
    }

    private var displayAvailable: Bool {
        // UI fixtures use an isolated data directory and an invisible, noninteractive panel.
        if unattendedTest { return !NSScreen.screens.isEmpty }
        guard !displaySuspended, !computerSuspended, !sessionSuspended, !sessionLocked,
              !NSScreen.screens.isEmpty, CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
            && session[kCGSessionOnConsoleKey as String] as? Bool != false
    }

    @objc private func systemDidChange(_ event: Notification) {
        switch event.name {
        case NSWorkspace.screensDidSleepNotification: displaySuspended = true
        case NSWorkspace.screensDidWakeNotification: displaySuspended = false
        case NSWorkspace.willSleepNotification: computerSuspended = true
        case NSWorkspace.didWakeNotification: computerSuspended = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionSuspended = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionSuspended = false
        case .init("com.apple.screenIsLocked"): sessionLocked = true
        case .init("com.apple.screenIsUnlocked"): sessionLocked = false
        case NSApplication.didChangeScreenParametersNotification: stage.displaysChanged()
        default: break
        }
        maintain()
    }

    private func maintain() {
        let width = preferences.independentWidth.map(NativePetSize.clamp) ?? nativeSize.width()
        if width != stage.width { stage.setWidth(width); writeStatus() }
        stage.setVisible(!preferences.hidden && displayAvailable)
    }

    private func setHidden(_ value: Bool) {
        preferences.hidden = value
        storage.save(preferences)
        maintain()
        writeStatus()
    }

    private func setSkin(_ skin: Skin) {
        preferences.skin = skin.rawValue
        storage.save(preferences)
        stage.setSkin(skin)
        writeStatus()
    }

    private func sizeChanged(_ width: Int?) {
        preferences.independentWidth = width
        storage.save(preferences)
        maintain()
        writeStatus()
    }

    private func writeStatus() {
        let frame = stage.frame
        var report: [String: Any] = [
            "app": bundleIdentity,
            "version": version,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "running": running,
            "visible": stage.isVisible,
            "hidden": preferences.hidden,
            "working": active as Any? ?? NSNull(),
            "skin": stage.skin.rawValue,
            "shownSkin": stage.shownSkin?.rawValue as Any? ?? NSNull(),
            "availableSkins": library.skins.map(\.rawValue),
            "pose": stage.pose?.rawValue as Any? ?? NSNull(),
            "frameIndex": stage.currentFrameIndex,
            "windowNumber": stage.windowNumber,
            "clickThrough": stage.isTransparentToMouse,
            "petWidth": stage.width,
            "sizeSetting": preferences.independentWidth == nil ? "follow-codex" : "independent",
            "roaming": preferences.roaming,
            "muted": preferences.muted,
            "completionVoice": preferences.completionVoice,
            "completedActions": stage.completedActions,
            "completedSwims": stage.completedSwims,
            "position": ["x": frame.minX, "y": frame.minY],
            "caption": stage.caption as Any? ?? NSNull(),
            "voice": stage.speechStatus,
            "captionWindowNumber": stage.captionWindowNumber,
            "captionFrame": screenRectValues(stage.captionFrame),
            "expressionPanel": stage.expressionStatus,
            "playbackError": stage.playbackError as Any? ?? NSNull(),
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let lastCommand { report["lastCommand"] = lastCommand }
        storage.write(report)
    }

    @objc private func receive(_ notification: Notification) {
        guard let message = notification.userInfo, let command = message["command"] as? String,
              let request = message["request"] as? String, UUID(uuidString: request) != nil else { return }
        let value = message["argument"] as? String
        var success = true
        switch command {
        case "status": break
        case "show": setHidden(false)
        case "hide": setHidden(true)
        case "skin":
            if let value, let skin = Skin(selection: value), library.skins.contains(skin) { setSkin(skin) }
            else { success = false }
        case "action":
            if let value, let pose = Pose(rawValue: value), Pose.actions.contains(pose) {
                if preferences.hidden { setHidden(false) }
                success = stage.play(pose)
            } else { success = false }
        case "quit": break
        default: success = false
        }
        lastCommand = ["request": request, "command": command, "ok": success]
        writeStatus()
        if command == "quit" { NSApp.terminate(nil) }
    }

    func menuWillOpen(_ menu: NSMenu) { fill(menu) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let label: String
        switch active {
        case true: label = "陪你处理 Codex 任务"
        case false: label = preferences.roaming ? "空闲，偶尔散步" : "空闲，原地休息"
        default: label = "正在读取 Codex 状态"
        }
        menu.addItem(withTitle: label, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for pose in Pose.actions where library.supports(pose, skin: stage.skin) {
            add(pose.actionTitle, #selector(play(_:)), value: pose.rawValue, to: menu)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "形象", action: nil, keyEquivalent: "").submenu = skinMenu()
        menu.addItem(withTitle: "宠物大小", action: nil, keyEquivalent: "").submenu = sizeMenu()
        add("闲时散步", #selector(toggleRoaming), checked: preferences.roaming, to: menu)
        add("语音", #selector(toggleMute), checked: !preferences.muted, to: menu)
        add("任务完成提醒", #selector(toggleCompletion), checked: preferences.completionVoice, to: menu)
        add(preferences.hidden ? "显示大肥鱼" : "隐藏大肥鱼", #selector(toggleHidden), to: menu)
        menu.addItem(.separator())
        if creditsURL != nil { add("素材署名…", #selector(viewCredits), to: menu) }
        add("退出大肥鱼", #selector(quit), to: menu)
    }

    private func skinMenu() -> NSMenu {
        let menu = NSMenu(title: "形象")
        menu.autoenablesItems = false
        for skin in library.skins {
            add(skin.title, #selector(chooseSkin(_:)), value: skin.rawValue, checked: stage.skin == skin, to: menu)
        }
        return menu
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu(title: "宠物大小")
        menu.autoenablesItems = false
        let follow = add("跟随 Codex 宠物大小", #selector(followSize), checked: preferences.independentWidth == nil, to: menu)
        menu.addItem(.separator())
        let item = NSMenuItem()
        item.view = PetSizeControl(width: stage.width, minimum: NativePetSize.minimum,
                                   maximum: NativePetSize.maximum) { [weak self, weak follow] width in
            self?.sizeChanged(width)
            follow?.state = .off
        }
        menu.addItem(item)
        add("恢复默认大小", #selector(resetSize), to: menu)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, value: String? = nil,
                     checked: Bool? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        if let checked { item.state = checked ? .on : .off }
        return item
    }

    @objc private func play(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let pose = Pose(rawValue: value) else { return }
        if preferences.hidden { setHidden(false) }
        stage.play(pose)
    }

    @objc private func chooseSkin(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let skin = Skin(rawValue: value) else { return }
        setSkin(skin)
    }

    @objc private func followSize() { sizeChanged(nil) }
    @objc private func resetSize() { sizeChanged(NativePetSize.defaultWidth) }
    @objc private func toggleHidden() { setHidden(!preferences.hidden) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleRoaming() {
        preferences.roaming.toggle()
        stage.roaming = preferences.roaming
        save()
    }
    @objc private func toggleMute() {
        preferences.muted.toggle()
        stage.muted = preferences.muted
        save()
        DistributedNotificationCenter.default().postNotificationName(
            preferencesNotification, object: storage.commandScope, userInfo: nil, deliverImmediately: true)
    }
    @objc private func toggleCompletion() {
        preferences.completionVoice.toggle()
        if !preferences.completionVoice { stage.cancelPendingCompletion() }
        save()
    }

    private func save() {
        storage.save(preferences)
        writeStatus()
    }

    private var creditsURL: URL? {
        let credits = resources.appendingPathComponent("素材署名.md")
        return FileManager.default.fileExists(atPath: credits.path) ? credits : nil
    }

    @objc private func viewCredits() { if let creditsURL { NSWorkspace.shared.open(creditsURL) } }
}

private func writeJSON(_ report: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let storage = Storage()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    guard let resources = Bundle.main.resourceURL else { throw AssetError("无法读取大肥鱼资源") }
    switch arguments {
    case ["--help"], ["-h"]:
        print("""
        DeepSeek 大肥鱼
        --status
        --native-status
        --verify-assets
        --action \(Pose.actions.map(\.rawValue).joined(separator: "|"))
        --skin figurine|original
        --show | --hide | --quit
        --version
        """)
    case ["--version"]:
        print(version)
    case ["--verify-assets"]:
        try WhaleVoiceCatalog(resources: resources).verify()
        try ExpressionPanel.verifyIcons(at: resources)
        try writeJSON(AnimationLibrary(resources: resources).verify())
    case ["--status"]:
        var status = storage.send("status") ?? storage.snapshot()
        status["running"] = storage.isRunning
        status["app"] = bundleIdentity
        try writeJSON(status)
    case ["--native-status"]:
        let service = storage.nativeExpressions
        var status = service.send("status") ?? service.snapshot()
        status["running"] = service.isRunning
        try writeJSON(status)
    case []:
        let library = AnimationLibrary(resources: resources)
        guard !library.skins.isEmpty else { throw AssetError("缺少大肥鱼动画资源") }
        guard let lock = try storage.claim() else {
            _ = storage.send("show")
            return
        }
        defer { close(lock) }
        let application = NSApplication.shared
        let delegate = WhalePet(storage: storage, library: library, resources: resources, version: version)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    default:
        let first = String(arguments[0].dropFirst(2))
        let argument = arguments.count == 2 ? arguments[1] : nil
        let single = ["show", "hide", "quit"].contains(first) && arguments.count == 1
        let action = first == "action" && argument.flatMap(Pose.init(rawValue:)).map(Pose.actions.contains) == true
        let skin = first == "skin" && argument.flatMap(Skin.init(selection:)) != nil
        guard arguments[0].hasPrefix("--"), single || action || skin else {
            throw AssetError("参数无效，请运行 --help")
        }
        guard let result = storage.send(first, argument: argument),
              let command = result["lastCommand"] as? [String: Any], command["ok"] as? Bool == true else {
            throw AssetError("大肥鱼未执行该操作，请查看 --status")
        }
        try writeJSON(result)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
