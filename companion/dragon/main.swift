import AppKit
import CoreGraphics
import Foundation

private struct ManagedInstance {
    let id: UUID
    let directory: URL
    let spawnSlot: Int
    let managerPID: pid_t?
}

private let managedInstance: ManagedInstance? = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["DESKTOP_PET_MANAGED"] == "1" else { return nil }
    guard let rawID = environment["DESKTOP_PET_INSTANCE_ID"], let id = UUID(uuidString: rawID),
          let path = environment["DESKTOP_PET_INSTANCE_DIR"], path.hasPrefix("/") else {
        fputs("Managed desktop pets need an instance UUID and an absolute data directory.\n", stderr)
        exit(2)
    }
    let managerPID = environment["DESKTOP_PET_MANAGER_PID"].flatMap(pid_t.init).flatMap { $0 > 1 ? $0 : nil }
    return ManagedInstance(
        id: id, directory: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
        spawnSlot: max(0, Int(environment["DESKTOP_PET_SPAWN_SLOT"] ?? "") ?? 0),
        managerPID: managerPID
    )
}()

private let dragonArtworkDirectory: URL? = {
    guard let path = ProcessInfo.processInfo.environment["DESKTOP_PET_DRAGON_ARTWORK_DIR"],
          path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
}()

private enum Request: String {
    case snapshot, reveal, hide, dismiss, playTogether, size, action, expressionPanel, interact, cancelInteraction

    var name: Notification.Name {
        let namespace = managedInstance.map {
            "com.local.desktop-pet-manager.engine.\($0.id.uuidString.lowercased())"
        } ?? "com.local.desktop-pet-studio.dragon-engine"
        return Notification.Name("\(namespace).\(rawValue)")
    }

    static func from(arguments: [String]) -> Request? {
        if arguments.contains("--quit") { return .dismiss }
        if arguments.contains("--hide") { return .hide }
        if arguments.contains("--show") { return .reveal }
        if arguments.contains("--size") { return .size }
        if arguments.contains("--action") { return .action }
        if arguments.contains("--expression-panel") { return .expressionPanel }
        if arguments.contains("--interact") { return .interact }
        if arguments.contains("--cancel-interaction") { return .cancelInteraction }
        if arguments.contains("--play-together") { return .playTogether }
        if arguments.contains("--status") { return .snapshot }
        return nil
    }
}

private enum RequestedSize {
    case follow
    case width(Int)

    init?(_ value: String) {
        if value == "follow" {
            self = .follow
        } else if let width = Int(value), (NativePetSize.minimum...NativePetSize.maximum).contains(width) {
            self = .width(width)
        } else {
            return nil
        }
    }
}

private let statusDirectory = managedInstance?.directory
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DesktopPetStudioDragon", isDirectory: true)
private let statusURL = statusDirectory.appendingPathComponent("status.json")
private let lockPath = statusDirectory.appendingPathComponent("instance.lock").path

private final class CompanionPreferences {
    private let file: URL?
    private var managedValues: [String: Any] = [:]

    init(directory: URL?) {
        file = directory?.appendingPathComponent("preferences.plist")
        if let file, let data = try? Data(contentsOf: file),
           let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let values = value as? [String: Any] {
            managedValues = values
        }
    }

    func object(forKey key: String) -> Any? {
        file == nil ? UserDefaults.standard.object(forKey: key) : managedValues[key]
    }

    func bool(forKey key: String) -> Bool {
        file == nil ? UserDefaults.standard.bool(forKey: key) : (managedValues[key] as? Bool ?? false)
    }

    func integer(forKey key: String) -> Int {
        file == nil ? UserDefaults.standard.integer(forKey: key) : (managedValues[key] as? Int ?? 0)
    }

    func stringArray(forKey key: String) -> [String]? {
        file == nil ? UserDefaults.standard.stringArray(forKey: key) : managedValues[key] as? [String]
    }

    func set(_ value: Any?, forKey key: String) {
        guard let file else {
            UserDefaults.standard.set(value, forKey: key)
            return
        }
        managedValues[key] = value
        save(to: file)
    }

    func setGreetingHistory(days: [String], count: Int) {
        guard let file else {
            let defaults = UserDefaults.standard
            defaults.set(days, forKey: "greetedDays")
            defaults.set(count, forKey: "greetingCount")
            defaults.synchronize()
            return
        }
        managedValues["greetedDays"] = days
        managedValues["greetingCount"] = count
        save(to: file)
    }

    private func save(to file: URL) {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: managedValues, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("GPT Dragon could not save its preferences: %@", error.localizedDescription)
        }
    }
}

final class Companion: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = CompanionPreferences(directory: managedInstance?.directory)
    private let stage = PetStage(animationResources: dragonArtworkDirectory,
                                 managedDialogueInstance: managedInstance.map { ($0.id, $0.directory) })
    private let monitor = ActivityMonitor()
    private let nativeSize = NativePetSizeReader()
    private let nativeLocator = NativePetLocator()
    private let star = StarPass()
    private var schedule = GreetingSchedule()
    private var menuButton: NSStatusItem?
    private var timer: Timer?
    private var nativeTimer: Timer?
    private var care: [CareLine] = []
    private var sequel: DispatchWorkItem?
    private var suspended = false
    private var previousUsable = false
    private var visible = true
    private var muted = false
    private var roaming = true
    private var working: Bool?
    private var social = true
    private var effectiveWidth = NativePetSize.defaultWidth
    private var nativeVisible = false
    private var recentRequestIDs: [String] = []
    private var followsNativeSize: Bool { defaults.object(forKey: "independentWidth") == nil }
    private var greetedDays: [String] { defaults.stringArray(forKey: "greetedDays") ?? [] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "greetings", withExtension: "json", subdirectory: "Care"),
           let data = try? Data(contentsOf: url) {
            care = (try? JSONDecoder().decode([CareLine].self, from: data)) ?? []
        }
        visible = !defaults.bool(forKey: "hidden")
        roaming = !defaults.bool(forKey: "roamingPaused")
        muted = defaults.bool(forKey: "muted")
        social = !defaults.bool(forKey: "socialDisabled")
        stage.setMuted(muted)
        stage.setRoaming(roaming)
        stage.setSocial(social)
        updateSize()
        restoreLastPosition()
        stage.onStarPass = { [weak self] companion, native in self?.star.play(companion: companion, native: native) }
        stage.onStarPassEnd = { [weak self] in self?.star.cancel() }
        stage.onContextMenu = { [weak self] in self?.buildMenu() ?? NSMenu() }
        stage.onChange = { [weak self] in self?.writeStatus() }
        stage.onExpressionSelected = { [weak self] action in self?.playExpression(action.rawValue) }
        if managedInstance == nil {
            menuButton = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            menuButton?.button?.title = "龙娘"
            menuButton?.button?.toolTip = "GPT 龙娘桌面伴侣"
            let menu = buildMenu()
            menu.delegate = self
            menuButton?.menu = menu
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(rest), name: event, object: nil)
        }
        for event in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: event, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(rest), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(resume), name: .init("com.apple.screenIsUnlocked"), object: nil)
        distributed.addObserver(self, selector: #selector(snapshot), name: Request.snapshot.name, object: nil)
        distributed.addObserver(self, selector: #selector(reveal), name: Request.reveal.name, object: nil)
        distributed.addObserver(self, selector: #selector(playTogether), name: Request.playTogether.name, object: nil)
        distributed.addObserver(self, selector: #selector(requestAction), name: Request.action.name, object: nil)
        distributed.addObserver(self, selector: #selector(requestExpressionPanel), name: Request.expressionPanel.name, object: nil)
        if managedInstance != nil {
            distributed.addObserver(self, selector: #selector(hide), name: Request.hide.name, object: nil)
            distributed.addObserver(self, selector: #selector(dismiss), name: Request.dismiss.name, object: nil)
            distributed.addObserver(self, selector: #selector(changeSize), name: Request.size.name, object: nil)
            distributed.addObserver(self, selector: #selector(requestInteraction), name: Request.interact.name, object: nil)
            distributed.addObserver(self, selector: #selector(requestInteractionCancel), name: Request.cancelInteraction.name, object: nil)
        }
        monitor.start { [weak self] active in
            guard let self else { return }
            self.working = active
            self.stage.setWorking(active)
            self.writeStatus()
        }
        poll()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let nativeTimer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.previousUsable else { return }
            self.refreshNative()
        }
        nativeTimer.tolerance = 0.09
        RunLoop.main.add(nativeTimer, forMode: .common)
        self.nativeTimer = nativeTimer
        writeStatus()
    }

    // Only display and input-idle metadata are queried. No input event tap is installed.
    private var displayAvailable: Bool {
        guard !suspended, !NSScreen.screens.isEmpty, CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
            && session[kCGSessionOnConsoleKey as String] as? Bool != false
    }

    private var recentlyUsed: Bool {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 300
    }

    @objc private func rest(_ note: Notification) {
        suspended = true
        previousUsable = false
        schedule.awaitReturn()
        cancelSequel()
        stage.hide()
        nativeVisible = false
        stage.setNativePet(nil)
        writeStatus()
    }

    @objc private func resume(_ note: Notification) {
        suspended = false
        schedule.awaitReturn()
        poll()
    }

    private func poll() {
        if let managerPID = managedInstance?.managerPID, getppid() != managerPID {
            quit()
            return
        }
        let usable = visible && displayAvailable
        if usable != previousUsable {
            if usable {
                updateSize()
                stage.show()
                refreshNative()
            } else {
                cancelSequel()
                stage.hide()
                nativeVisible = false
                stage.setNativePet(nil)
            }
            previousUsable = usable
        }
        let date = Date()
        if !stage.interactionInProgress && schedule.shouldGreet(at: date, greetedDays: greetedDays, available: usable && recentlyUsed) {
            greet(day: schedule.day(date))
        }
    }

    private func cancelSequel() {
        sequel?.cancel()
        sequel = nil
    }

    private func greet(day: String) {
        let count = defaults.integer(forKey: "greetingCount")
        let greetings = care.filter { ["hello", "bailong"].contains($0.id) }
        if greetings.isEmpty {
            stage.play("greeting")
        } else {
            let line = greetings[count % greetings.count]
            stage.say(line.text, recording: line.id)
        }
        defaults.setGreetingHistory(days: Array((greetedDays + [day]).suffix(21)), count: count + 1)
        writeStatus()
        cancelSequel()
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.visible, self.displayAvailable, self.recentlyUsed else { return }
            self.sayCare(index: count)
        }
        sequel = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3, execute: next)
    }

    private func sayCare(index: Int) {
        let other = care.filter { !["hello", "bailong"].contains($0.id) }
        guard !other.isEmpty else { stage.say("今天过得怎么样？"); return }
        let line = other[index % other.count]
        stage.say(line.text, recording: line.id)
        writeStatus()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "GPT 龙娘")
        fill(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if previousUsable { refreshNative() }
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let status: String
        switch working {
        case true: status = "正在陪你处理 Codex 任务"
        case false: status = roaming ? "空闲 · 散步和玩耍" : "空闲 · 原地休息"
        default: status = "正在查看 Codex 状态"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        add("打个招呼", #selector(action(_:)), "greeting", to: menu)
        add("关心我一下", #selector(action(_:)), "care", to: menu)
        add("跳支舞", #selector(action(_:)), "dance", to: menu)
        add("撒个娇", #selector(action(_:)), "playful", to: menu)
        menu.addItem(.separator())
        let visit = add("和 Codex 龙娘传星星", #selector(playTogether), nil, to: menu)
        visit.isEnabled = stage.nativeVisitUnavailableReason == nil
        visit.toolTip = stage.nativeVisitUnavailableReason
        add("两只龙娘互动", #selector(toggleSocial), nil, to: menu).state = social ? .on : .off
        menu.addItem(.separator())
        let size = menu.addItem(withTitle: "宠物大小", action: nil, keyEquivalent: "")
        size.submenu = sizeMenu()
        add("闲时散步", #selector(toggleRoaming), nil, to: menu).state = roaming ? .on : .off
        add("语音", #selector(toggleMuted), nil, to: menu).state = muted ? .off : .on
        add(visible ? "暂时隐藏龙娘" : "显示龙娘", #selector(toggleVisible), nil, to: menu)
        menu.addItem(.separator())
        add("退出龙娘", #selector(quit), nil, to: menu)
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu(title: "宠物大小")
        menu.autoenablesItems = false
        let follow = add("跟随 Codex 宠物大小", #selector(followNativeSize), nil, to: menu)
        follow.state = followsNativeSize ? .on : .off
        menu.addItem(.separator())
        let slider = NSMenuItem()
        slider.view = PetSizeControl(width: effectiveWidth, minimum: NativePetSize.minimum, maximum: NativePetSize.maximum) { [weak self, weak follow] value in
            guard let self else { return }
            self.setIndependentWidth(value)
            follow?.state = .off
        }
        menu.addItem(slider)
        add("恢复默认大小", #selector(resetSize), nil, to: menu)
        return menu
    }

    private func updateSize() {
        let width = followsNativeSize ? nativeSize.width() : NativePetSize.clamp(defaults.integer(forKey: "independentWidth"))
        if width != effectiveWidth {
            effectiveWidth = width
            stage.setPetWidth(width)
        }
    }

    private func setIndependentWidth(_ value: Int) {
        defaults.set(NativePetSize.clamp(value), forKey: "independentWidth")
        updateSize()
    }

    @objc private func resetSize() { setIndependentWidth(NativePetSize.defaultWidth) }
    @objc private func followNativeSize() {
        defaults.set(nil, forKey: "independentWidth")
        updateSize()
        writeStatus()
    }

    private func refreshNative() {
        updateSize()
        let rect = social ? nativeLocator.current(mascotWidth: CGFloat(nativeSize.width()))?.frame : nil
        nativeVisible = rect != nil
        stage.setNativePet(rect)
    }

    @objc private func toggleSocial() {
        social.toggle()
        defaults.set(!social, forKey: "socialDisabled")
        stage.setSocial(social)
        refreshNative()
        writeStatus()
    }

    @objc private func playTogether(_ sender: Any?) {
        if let note = sender as? Notification { recordRequest(note) }
        guard visible, displayAvailable, social else {
            if managedInstance != nil { writeStatus() }
            return
        }
        refreshNative()
        if stage.nativeVisitUnavailableReason == nil {
            cancelSequel()
            _ = stage.visitNativePet()
        }
        writeStatus()
    }

    private func restoreLastPosition() {
        if let bytes = try? Data(contentsOf: statusURL),
           let report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let pos = report["position"] as? [String: Double],
           let x = pos["x"], let y = pos["y"],
           stage.restorePosition(NSPoint(x: x, y: y)) {
            return
        }
        guard let instance = managedInstance, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let spacing: CGFloat = 260
        let columns = max(1, Int(area.width / spacing))
        let rows = max(1, Int(area.height / spacing))
        let slot = instance.spawnSlot % (columns * rows)
        let x = max(area.minX, area.maxX - CGFloat(effectiveWidth) - CGFloat(slot % columns) * spacing)
        let y = area.minY + CGFloat(slot / columns) * spacing
        stage.restorePosition(NSPoint(x: x, y: y))
    }

    @discardableResult
    private func add(_ title: String, _ selector: Selector, _ id: String?, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func action(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        playExpression(id)
    }

    private func playExpression(_ id: String) {
        if !visible { toggleVisible() }
        guard visible, displayAvailable else { return }
        cancelSequel()
        if id == "care" { sayCare(index: Int.random(in: 0..<60)) }
        else { stage.play(id) }
    }

    @objc private func toggleVisible() { setVisible(!visible) }

    private func setVisible(_ value: Bool) {
        if value != visible {
            visible = value
            defaults.set(!visible, forKey: "hidden")
            poll()
        }
        writeStatus()
    }

    @objc private func toggleMuted() {
        muted.toggle()
        defaults.set(muted, forKey: "muted")
        stage.setMuted(muted)
        writeStatus()
    }

    @objc private func toggleRoaming() {
        roaming.toggle()
        defaults.set(!roaming, forKey: "roamingPaused")
        stage.setRoaming(roaming)
        writeStatus()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func recordRequest(_ note: Notification) {
        guard managedInstance != nil, let rawID = note.userInfo?["requestID"] as? String,
              let id = UUID(uuidString: rawID) else { return }
        recentRequestIDs.append(id.uuidString)
        if recentRequestIDs.count > 32 { recentRequestIDs.removeFirst() }
    }

    @objc private func snapshot(_ note: Notification) {
        recordRequest(note)
        writeStatus()
    }

    @objc private func reveal(_ note: Notification) {
        recordRequest(note)
        if !visible || managedInstance != nil { setVisible(true) }
    }

    @objc private func hide(_ note: Notification) {
        recordRequest(note)
        setVisible(false)
    }

    @objc private func dismiss(_ note: Notification) {
        recordRequest(note)
        quit()
    }

    @objc private func changeSize(_ note: Notification) {
        guard let value = note.userInfo?["width"] as? String, let size = RequestedSize(value) else { return }
        recordRequest(note)
        switch size {
        case .follow:
            followNativeSize()
        case .width(let width):
            setIndependentWidth(width)
            writeStatus()
        }
    }

    @objc private func requestAction(_ note: Notification) {
        guard let id = note.userInfo?["value"] as? String,
              WhiteDragonExpression(rawValue: id) != nil || id == "task_done" else { return }
        playExpression(id)
        recordRequest(note)
        writeStatus()
    }

    @objc private func requestExpressionPanel(_ note: Notification) {
        guard let raw = note.userInfo?["value"] as? String, let request = WhiteDragonPanelRequest(rawValue: raw) else { return }
        stage.controlExpressions(request)
        recordRequest(note)
        writeStatus()
    }

    @objc private func requestInteraction(_ note: Notification) {
        guard let raw = note.userInfo?["value"] as? String, let request = WhiteDragonInteraction.parse(raw) else { return }
        if working == false, stage.startInteraction(request) { cancelSequel() }
        recordRequest(note)
        writeStatus()
    }

    @objc private func requestInteractionCancel(_ note: Notification) {
        let id: UUID?
        if let raw = note.userInfo?["value"] as? String {
            guard let requestedID = UUID(uuidString: raw) else { return }
            id = requestedID
        } else {
            id = nil
        }
        stage.cancelInteraction(id: id)
        recordRequest(note)
        writeStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !visible { toggleVisible() }
        return true
    }

    private func writeStatus() {
        var report = stage.observation
        report["pid"] = ProcessInfo.processInfo.processIdentifier
        report["menuBarIcon"] = menuButton != nil
        report["observedAt"] = Date().timeIntervalSince1970
        if let instance = managedInstance {
            report["instanceID"] = instance.id.uuidString
            report["wantedVisible"] = visible
            report["recentRequestIDs"] = recentRequestIDs
        }
        report["greetingCount"] = defaults.integer(forKey: "greetingCount")
        report["lastGreetingDay"] = greetedDays.last ?? ""
        report["schedule"] = "first-use"
        report["taskStateKnown"] = working != nil
        report["interactionReady"] = working == false && stage.interactionReady
        report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        report["sizeSetting"] = followsNativeSize ? "follow-codex" : "independent"
        report["petWidth"] = effectiveWidth
        report["nativePetVisible"] = nativeVisible
        report["starPassesStarted"] = star.passesStarted
        report["starPassesCompleted"] = star.passesCompleted
        do {
            try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: statusURL, options: .atomic)
        } catch {
            NSLog("GPT Dragon could not save its local status: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        nativeTimer?.invalidate()
        cancelSequel()
        monitor.stop()
        stage.hide()
        writeStatus()
    }
}

private func instanceLockReleased() -> Bool {
    let descriptor = open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return errno == ENOENT }
    defer { close(descriptor) }
    return flock(descriptor, LOCK_EX | LOCK_NB) == 0
}

if let request = Request.from(arguments: CommandLine.arguments) {
    guard managedInstance != nil || [.snapshot, .playTogether, .action, .expressionPanel].contains(request) else {
        fputs("This command needs a managed desktop pet instance.\n", stderr)
        exit(2)
    }
    let requested = Date().timeIntervalSince1970
    let requestID = managedInstance.map { _ in UUID().uuidString }
    var requestInfo: [AnyHashable: Any] = requestID.map { ["requestID": $0] } ?? [:]
    if request == .size {
        let arguments = CommandLine.arguments
        guard let option = arguments.firstIndex(of: "--size"), arguments.indices.contains(option + 1),
              RequestedSize(arguments[option + 1]) != nil else {
            fputs("--size requires a width from \(NativePetSize.minimum) to \(NativePetSize.maximum), or follow.\n", stderr)
            exit(2)
        }
        requestInfo["width"] = arguments[option + 1]
    }
    let parameters = Array(CommandLine.arguments.dropFirst())
    let value = parameters.count == 2 ? parameters[1] : nil
    var interactionID: String?
    switch request {
    case .action:
        guard let value, WhiteDragonExpression(rawValue: value) != nil || value == "task_done" else {
            fputs("--action requires a white dragon expression ID.\n", stderr)
            exit(2)
        }
        requestInfo["value"] = value
    case .expressionPanel:
        guard let value, WhiteDragonPanelRequest(rawValue: value) != nil else {
            fputs("--expression-panel requires show, hide, next or previous.\n", stderr)
            exit(2)
        }
        requestInfo["value"] = value
    case .interact:
        guard let value, let interaction = WhiteDragonInteraction.parse(value) else {
            fputs("--interact requires a valid paired interaction request.\n", stderr)
            exit(2)
        }
        interactionID = interaction.id.uuidString.lowercased()
        requestInfo["value"] = value
    case .cancelInteraction:
        guard parameters.count == 1 || value.flatMap(UUID.init(uuidString:)) != nil else {
            fputs("--cancel-interaction takes an optional interaction UUID.\n", stderr)
            exit(2)
        }
        requestInfo["value"] = value
    default: break
    }
    DistributedNotificationCenter.default().postNotificationName(
        request.name, object: nil, userInfo: requestInfo, deliverImmediately: true
    )
    for _ in 0..<(managedInstance == nil ? 35 : 70) {
        if let data = try? Data(contentsOf: statusURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stamp = json["observedAt"] as? Double, stamp >= requested,
           managedInstance.map({ json["instanceID"] as? String == $0.id.uuidString }) ?? true,
           requestID.map({ (json["recentRequestIDs"] as? [String])?.contains($0) == true }) ?? true,
           request != .dismiss || instanceLockReleased() {
            if let interactionID, (json["interaction"] as? [String: Any])?["id"] as? String != interactionID {
                fputs("The white dragon is unavailable for that interaction.\n", stderr)
                exit(1)
            }
            FileHandle.standardOutput.write(data)
            print("")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fputs("Desktop companion did not reply.\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
let instanceLock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
guard instanceLock >= 0 else { exit(2) }
if flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    guard errno == EWOULDBLOCK else { exit(2) }
    DistributedNotificationCenter.default().postNotificationName(
        Request.reveal.name, object: nil, userInfo: nil, deliverImmediately: true
    )
    exit(0)
}

let application = NSApplication.shared
let companion = Companion()
application.delegate = companion
application.run()
