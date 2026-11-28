import AppKit
import AVFoundation
import ImageIO

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: NSSize, level: NSWindow.Level = .floating) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        animationBehavior = .none
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}

private struct PetFrame {
    let image: CGImage
    private let alpha: [UInt8]

    init?(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.image = image

        let width = image.width
        let height = image.height
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        alpha = (0..<(width * height)).map { bytes[$0 * 4 + 3] }
    }

    func acceptsClick(_ point: NSPoint, in bounds: NSRect) -> Bool {
        guard bounds.contains(point) else { return false }
        let x = min(image.width - 1, Int((point.x - bounds.minX) / bounds.width * CGFloat(image.width)))
        let row = min(image.height - 1, Int((point.y - bounds.minY) / bounds.height * CGFloat(image.height)))
        let y = image.height - 1 - row
        return alpha[y * image.width + x] >= 48
    }

    var portrait: NSImage {
        let width = CGFloat(image.width)
        let side = floor(width * 0.67)
        let crop = CGRect(x: (width - side) / 2, y: floor(CGFloat(image.height) * 0.09),
                          width: side, height: side)
        let portrait = image.cropping(to: crop) ?? image
        return NSImage(cgImage: portrait, size: NSSize(width: portrait.width, height: portrait.height))
    }
}

private final class PetSpriteView: NSView {
    var sprite: PetFrame?
    var imageBounds: NSRect { bounds.applying(poseTransform) }
    private var poseTransform = CGAffineTransform.identity
    var pressed: ((NSPoint) -> Void)?
    var dragged: ((NSPoint) -> Void)?
    var released: ((NSPoint) -> Void)?
    var contextMenu: (() -> NSMenu)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("白龙桌宠")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let sprite, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        context.interpolationQuality = .high
        context.draw(sprite.image, in: imageBounds)
    }

    func pose(lift: CGFloat = 0, stretch: CGFloat = 1) {
        let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: stretch, tx: 0, ty: lift)
        guard transform != poseTransform else { return }
        poseTransform = transform
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { dragged?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { released?(NSEvent.mouseLocation) }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

private final class PetBubbleView: NSView {
    static let padding = NSSize(width: 9, height: 5)

    private let words: NSAttributedString
    private let textSize: NSSize

    init(_ message: String, maximumWidth: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 16
        paragraph.lineBreakMode = .byWordWrapping
        let halo = NSShadow()
        halo.shadowColor = NSColor.white.withAlphaComponent(0.34)
        halo.shadowBlurRadius = 0.7
        words = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.black,
            .shadow: halo,
            .paragraphStyle: paragraph
        ])
        let measured = words.boundingRect(
            with: NSSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        textSize = NSSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 1)
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: textSize.width + 2 * Self.padding.width,
            height: textSize.height + 2 * Self.padding.height
        ))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        NSColor.white.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        words.draw(
            with: NSRect(
                x: Self.padding.width,
                y: Self.padding.height,
                width: textSize.width,
                height: textSize.height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}

private struct PetAnimation {
    let frames: [PetFrame]
    let frameTimes: [TimeInterval]
    let duration: TimeInterval

    init(frames: [PetFrame], frameLengths: [TimeInterval]) {
        self.frames = frames
        var end: TimeInterval = 0
        frameTimes = frames.indices.map { index in
            end += frameLengths[min(index, frameLengths.count - 1)]
            return end
        }
        duration = end
    }

    func index(at elapsed: TimeInterval) -> Int {
        let time = max(elapsed, 0).truncatingRemainder(dividingBy: duration)
        return frameTimes.firstIndex { time < $0 } ?? 0
    }
}

struct PetWalk {
    let start: NSPoint
    let destination: NSPoint
    let duration: TimeInterval
    var elapsed: TimeInterval = 0

    var animation: String { destination.x < start.x ? "running-left" : "running-right" }
    var arrived: Bool { elapsed >= duration }

    init(start: NSPoint, destination: NSPoint) {
        self.start = start
        self.destination = destination
        duration = max(0.75, hypot(destination.x - start.x, destination.y - start.y) / 153)
    }

    var position: NSPoint {
        let t = min(elapsed / duration, 1)
        let eased = t * t * (3 - 2 * t)
        return NSPoint(
            x: start.x + (destination.x - start.x) * eased,
            y: start.y + (destination.y - start.y) * eased
        )
    }
}

final class PetStage: NSObject, AVAudioPlayerDelegate {
    private enum Mode: String {
        case idle, walking, ambient, working, deliberate, dragging, visiting, separating, interacting
    }

    private enum EncounterTrigger: String {
        case menu, idle, nativeDrag
    }

    private struct Encounter {
        enum Phase: String {
            case approaching, greeting, waiting
        }

        let trigger: EncounterTrigger
        let dance: Bool
        var target: NSRect
        var phase = Phase.approaching
        var until: TimeInterval = 0
    }

    private struct Gesture {
        let mouseStart: NSPoint
        let windowStart: NSPoint
        var dragged = false
    }

    private struct DialoguePlayback {
        enum Outcome: String {
            case speaking, caption, completed, muted, cancelled, failed
        }

        struct Event {
            let turn: WhiteDragonDialogue.Turn
            let startedAt: TimeInterval
            var endedAt: TimeInterval?
            var outcome: Outcome

            var status: [String: Any] {
                ["index": turn.index, "speaker": turn.speaker.rawValue,
                 "text": turn.text, "file": turn.file, "startedAt": startedAt,
                 "endedAt": endedAt as Any? ?? NSNull(),
                 "completedAt": (outcome == .completed ? endedAt : nil) as Any? ?? NSNull(),
                 "outcome": outcome.rawValue]
            }
        }

        let script: WhiteDragonDialogue
        let ownTurns: [WhiteDragonDialogue.Turn]
        let players: [Int: AVAudioPlayer]
        var permit: WhiteDragonDialoguePermit?
        var events: [Event] = []

        var current: Event? { events.last.flatMap { $0.endedAt == nil ? $0 : nil } }
        var next: WhiteDragonDialogue.Turn? {
            ownTurns.indices.contains(events.count) ? ownTurns[events.count] : nil
        }
        var finished: Bool {
            events.count == ownTurns.count && events.allSatisfy { $0.outcome == .completed || $0.outcome == .muted }
        }

        func deadline(for turn: WhiteDragonDialogue.Turn, in request: WhiteDragonInteraction) -> TimeInterval {
            let nextIndex = turn.index + 1
            let limit = script.turns.indices.contains(nextIndex) ? script.turns[nextIndex].offset : request.duration
            return request.startAt + limit - 0.04
        }

        func status(id: UUID, phase: String, speaking: Bool) -> [String: Any] {
            ["id": id.uuidString.lowercased(), "script": script.script, "phase": phase,
             "currentTurn": current?.turn.index as Any? ?? NSNull(),
             "speaker": current?.turn.speaker.rawValue as Any? ?? NSNull(),
             "speaking": speaking,
             "completedTurns": events.filter { $0.outcome == .completed || $0.outcome == .muted }.map { $0.turn.index },
             "turns": events.map(\.status)]
        }
    }

    private static let frameLengths: [String: [TimeInterval]] = [
        "idle": [0.28, 0.11, 0.11, 0.14, 0.14, 0.32],
        "waving": [0.11, 0.14, 0.16, 0.19],
        "waiting": [0.56, 0.32, 0.35, 0.57],
        "jumping": [0.14, 0.13, 0.17, 0.13, 0.24],
        "dance": [0.13],
        "running": [0.36, 0.24, 0.24, 0.32, 0.28, 0.36],
        "running-left": [0.10],
        "running-right": [0.10],
    ]

    private static let ambientAnimations = ["waiting", "jumping", "dance", "waving"]
    private static let silenceRecordedAudioInTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["DESKTOP_PET_MANAGED"] == "1" && environment["DESKTOP_PET_HUB_QUIET"] == "1"
            && environment["DESKTOP_PET_AUDIO_TEST_SILENT"] == "1"
    }()

    private var size = NSSize(width: 112, height: 112 * 208.0 / 192.0)
    private let panel: PetPanel
    private let bubble: PetPanel
    private let sprite: PetSpriteView
    private let resourceURL: URL?
    private let managedDialogueInstance: (id: UUID, directory: URL)?
    private let dialogueDirectory: URL?
    private let dialogueLibrary: WhiteDragonDialogueLibrary?
    private let animations: [String: PetAnimation]
    private let expressions: WhiteDragonExpressions
    private let effect = DragonEffectOverlay()
    private let synthesizer = AVSpeechSynthesizer()
    private var audio: AVAudioPlayer?
    private var voiceDuration: TimeInterval = 0
    private var voiceElapsed: TimeInterval = 0
    private var timer: Timer?
    private var screenID: NSNumber?
    private var placed = false
    private var working = false
    private var roaming = true
    private var muted = false
    private var mode = Mode.idle
    private var gesture: Gesture?
    private var walk: PetWalk?
    private var nextBehavior: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var animationName = "idle"
    private var animationStart: TimeInterval = 0
    private var displayIndex: Int?
    private var standUntil: TimeInterval = 0
    private var bubbleUntil: TimeInterval = 0
    private var walkNext = true
    private var ambientIndex = 0
    private var walksStarted = 0
    private var walksFinished = 0
    private var lastSpeech = ""
    private var lastSpeechSource = ""
    private var lastWalkStart: NSPoint?
    private var lastWalkDestination: NSPoint?
    private var lastWalkAnimation: String?
    private var social = true
    private var nativePet: NSRect?
    private var encounter: Encounter?
    private var nextNativeVisit: TimeInterval = 0
    private var nextNativeDragGreeting: TimeInterval = 0
    private var draggedNativePet = false
    private var nativeDragReleasedAt: TimeInterval?
    private var nativeVisitsStarted = 0
    private var nativeVisitsFinished = 0
    private var nativeHandoffs = 0
    private var lastNativeVisitTrigger: String?
    private var hoverStarted: TimeInterval?
    private var hoverHideAfter: TimeInterval = 0
    private var needsHoverExit = false
    private var pinnedExpressions = false
    private var lastBodyPoint = NSPoint.zero
    private var previousPointer = NSPoint.zero
    private var selectedExpression: WhiteDragonExpression?
    private var lastExpression: WhiteDragonExpression?
    private var expressionStart: TimeInterval = 0
    private var activeInteraction: ActiveWhiteDragonInteraction?
    private var dialoguePlayback: DialoguePlayback?
    private var lastInteraction: [String: Any]?
    private var lastDialogue: [String: Any]?
    private var interactionsCompleted = 0
    private var interactionsCancelled = 0
    var onChange: (() -> Void)?
    var onExpressionSelected: ((WhiteDragonExpression) -> Void)?
    var onContextMenu: (() -> NSMenu)?
    var onStarPass: ((NSRect, NSRect) -> Void)?
    var onStarPassEnd: (() -> Void)?

    init(resources: URL? = Bundle.main.resourceURL, animationResources: URL? = nil,
         managedDialogueInstance: (id: UUID, directory: URL)? = nil) {
        resourceURL = resources
        self.managedDialogueInstance = managedDialogueInstance
        let dialogueDirectory = resources?.appendingPathComponent("Dialogue", isDirectory: true)
        self.dialogueDirectory = dialogueDirectory
        dialogueLibrary = dialogueDirectory.flatMap {
            guard let data = try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) else { return nil }
            return try? JSONDecoder().decode(WhiteDragonDialogueLibrary.self, from: data)
        }
        panel = PetPanel(size: size)
        bubble = PetPanel(size: .zero, level: .floating + 1)
        sprite = PetSpriteView(frame: NSRect(origin: .zero, size: size))
        let animations = Self.loadAnimations(animationResources ?? resources)
        self.animations = animations
        expressions = WhiteDragonExpressions(icons: Dictionary(uniqueKeysWithValues:
            WhiteDragonExpression.allCases.compactMap { action in
                guard let animation = animations[action.animation] else { return nil }
                let frame = animation.frames[animation.index(at: animation.duration * action.iconTime)]
                return (action, frame.portrait)
            }))
        super.init()
        panel.title = "白龙桌宠"
        panel.contentView = sprite
        sprite.pressed = { [weak self] in self?.press(at: $0) }
        sprite.dragged = { [weak self] in self?.drag(to: $0) }
        sprite.released = { [weak self] in self?.release(at: $0) }
        sprite.contextMenu = { [weak self] in self?.onContextMenu?() ?? NSMenu() }
        expressions.onSelect = { [weak self] action in
            guard let self else { return }
            if let onExpressionSelected = self.onExpressionSelected { onExpressionSelected(action) }
            else { self.play(action.rawValue) }
        }
        expressions.onChange = { [weak self] in self?.onChange?() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var currentScreen: NSScreen? {
        NSScreen.screens.first { screenNumber($0) == screenID }
    }

    func show() {
        guard !panel.isVisible else { return }
        placeOnScreen()
        guard placed else { return }
        let timestamp = now
        lastTick = timestamp
        nextNativeVisit = max(nextNativeVisit, timestamp + 12)
        if working {
            mode = .working
            setAnimation("running", at: timestamp)
        } else {
            rest(at: timestamp, delay: 5)
        }
        drawFrame(at: timestamp)
        updateMouseTarget()
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        dismissExpressions()
        cancelInteraction()
        endExpression()
        clearCaption()
        endEncounter(at: now)
        draggedNativePet = false
        nativeDragReleasedAt = nil
        walk = nil
        gesture = nil
        mode = working ? .working : .idle
    }

    func setWorking(_ value: Bool) {
        guard working != value else { return }
        working = value
        let timestamp = now
        if value { cancelInteraction() }
        endEncounter(at: timestamp)
        if selectedExpression != nil { return }
        if value {
            draggedNativePet = false
            nativeDragReleasedAt = nil
            walk = nil
            mode = .working
            setAnimation("running", at: timestamp)
        } else {
            rest(at: timestamp, delay: 6)
        }
    }

    func setRoaming(_ enabled: Bool) {
        guard roaming != enabled else { return }
        roaming = enabled
        endEncounter(at: now)
        if !enabled {
            draggedNativePet = false
            nativeDragReleasedAt = nil
        }
        if mode == .walking || mode == .separating || (!enabled && mode == .ambient) {
            rest(at: now)
        }
        if enabled {
            nextBehavior = now + 2.5
        }
    }

    func setMuted(_ enabled: Bool) {
        muted = enabled
        if enabled {
            if var playback = dialoguePlayback, playback.current?.outcome == .speaking {
                playback.events[playback.events.count - 1].outcome = .caption
                dialoguePlayback = playback
                lastSpeechSource = "muted"
            }
            stopVoice()
        }
    }

    func setPetWidth(_ width: Int) {
        let next = NSSize(width: CGFloat(width), height: CGFloat(width) * 208 / 192)
        guard width > 0, next != size else { return }
        let previous = panel.frame
        cancelInteraction()
        endEncounter(at: now)
        if mode == .walking || mode == .separating { rest(at: now, delay: 3) }
        gesture = nil
        size = next
        let foot = NSPoint(x: previous.midX - next.width / 2, y: previous.minY)
        let origin = currentScreen.map { clampedOrigin(foot, on: $0) } ?? foot
        panel.setFrame(NSRect(origin: origin, size: next), display: true)
        sprite.frame = NSRect(origin: .zero, size: next)
        sprite.needsDisplay = true
        if bubble.isVisible { placeBubble() }
        if expressions.window.isVisible { expressions.show(near: panel.frame, on: currentScreen) }
        updateMouseTarget()
    }

    func setSocial(_ enabled: Bool) {
        guard social != enabled else { return }
        social = enabled
        endEncounter(at: now)
        draggedNativePet = false
        nativeDragReleasedAt = nil
        if mode == .separating { rest(at: now) }
        if enabled { nextNativeVisit = now + 10 }
    }

    func setNativePet(_ rect: NSRect?) {
        let rect = rect.flatMap { frame in
            frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
                && frame.maxX.isFinite && frame.maxY.isFinite ? frame : nil
        }
        let previous = nativePet
        guard previous != rect else { return }
        nativePet = rect
        let timestamp = now
        guard let rect else {
            endEncounter(at: timestamp)
            draggedNativePet = false
            nativeDragReleasedAt = nil
            if mode == .separating { rest(at: timestamp) }
            nextNativeVisit = max(nextNativeVisit, timestamp + 10)
            return
        }
        guard let previous else {
            nextNativeVisit = max(nextNativeVisit, timestamp + 10)
            return
        }
        if mode == .separating && nativeShift(from: previous, to: rect) >= 5 {
            rest(at: timestamp)
        }
        let pointer = NSEvent.mouseLocation
        let centerMoved = hypot(rect.midX - previous.midX, rect.midY - previous.midY) >= 2
        if social, panel.isVisible, !working, roaming, gesture == nil, centerMoved {
            let pointerInNewFrame = rect.insetBy(dx: -18, dy: -18).contains(pointer)
            let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
            let duringDrag = buttonDown && (pointerInNewFrame || previous.insetBy(dx: -18, dy: -18).contains(pointer))
            let afterQuickDrag = !buttonDown && pointerInNewFrame && CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .leftMouseDragged
            ) < 0.75
            if duringDrag || afterQuickDrag {
                draggedNativePet = true
                nativeDragReleasedAt = nil
            }
        }
        if let encounter {
            let shifted = nativeShift(from: encounter.target, to: rect) >= 12
            if panel.frame.intersects(rect) || (shifted && (encounter.phase != .approaching || draggedNativePet)) {
                endEncounter(at: timestamp)
            }
        }
    }

    var nativeVisitUnavailableReason: String? {
        if !panel.isVisible { return "龙娘当前已隐藏" }
        if !social { return "双龙互动已关闭" }
        if activeInteraction != nil || selectedExpression != nil || expressions.window.isVisible { return "白龙正在忙" }
        guard let nativePet else { return "需要先在 Codex 显示白龙" }
        guard let screen = currentScreen,
              screen.frame.contains(NSPoint(x: nativePet.midX, y: nativePet.midY)) else {
            return "请先把两只桌宠移到同一屏幕"
        }
        if panel.frame.intersects(nativePet) { return "请先把两只桌宠稍微分开" }
        if gesture != nil { return "请先放开龙娘" }
        if !working && roaming && encounterDestination(for: nativePet, on: screen) == nil {
            return "白龙身边暂时没有空位"
        }
        return nil
    }

    @discardableResult
    func visitNativePet() -> Bool {
        guard nativeVisitUnavailableReason == nil, let nativePet else { return false }
        return startEncounter(with: nativePet, trigger: .menu, at: now)
    }

    func say(_ message: String) {
        say(message, recording: nil)
    }

    func say(_ message: String, recording: String?) {
        perform(message, animation: "waving", recording: recording)
    }

    func play(_ choice: String) {
        if let action = WhiteDragonExpression(rawValue: choice) {
            perform(action.line, animation: action.animation, recording: choice, expression: action)
        } else if choice == "task_done" {
            perform("任务完成啦！", animation: "jumping", recording: choice)
        }
    }

    func controlExpressions(_ request: WhiteDragonPanelRequest) {
        switch request {
        case .show:
            guard panel.isVisible, gesture == nil else { return }
            cancelInteraction()
            pauseRoamingForExpressions()
            pinnedExpressions = true
            expressions.show(near: panel.frame, on: currentScreen)
        case .hide: dismissExpressions()
        case .next: expressions.changePage(by: 1)
        case .previous: expressions.changePage(by: -1)
        }
    }

    var interactionInProgress: Bool { activeInteraction != nil }

    var interactionReady: Bool {
        panel.isVisible && !working && gesture == nil && activeInteraction == nil && encounter == nil
            && !expressions.window.isVisible && hoverStarted == nil && bubbleUntil == 0
            && (mode == .idle || mode == .ambient)
    }

    @discardableResult
    func startInteraction(_ request: WhiteDragonInteraction) -> Bool {
        let timestamp = now
        guard interactionReady, (timestamp - 0.25...timestamp + 10).contains(request.startAt),
              lastInteraction?["id"] as? String != request.id.uuidString.lowercased(),
              let screen = currentScreen,
              screen.frame.contains(NSPoint(x: request.peer.value.midX, y: request.peer.value.midY)) else { return false }
        if let dialogue = request.dialogue {
            var permit: WhiteDragonDialoguePermit?
            if dialogue.permitRequired == true {
                guard timestamp < request.startAt, let managedDialogueInstance,
                      let verified = WhiteDragonDialoguePermit(interactionID: request.id, instanceID: managedDialogueInstance.id,
                                                             directory: managedDialogueInstance.directory) else { return false }
                permit = verified
            }
            guard let playback = prepareDialogue(dialogue, permit: permit) else { return false }
            dialoguePlayback = playback
        }
        let goal = NSPoint(x: request.destination.x - size.width / 2, y: request.destination.y - size.height / 2)
        let destination = clampedOrigin(goal, on: screen)
        walk = nil
        mode = .interacting
        setAnimation("idle", at: timestamp)
        activeInteraction = ActiveWhiteDragonInteraction(request: request, origin: panel.frame.origin, destination: destination)
        onChange?()
        return true
    }

    func cancelInteraction(id: UUID? = nil) {
        guard let scene = activeInteraction, id == nil || id == scene.request.id else { return }
        finishInteraction(scene, phase: .cancelled, at: now)
    }

    private func interactionStatus(_ scene: ActiveWhiteDragonInteraction, phase: WhiteDragonInteraction.Phase) -> [String: Any] {
        ["id": scene.request.id.uuidString.lowercased(), "behavior": scene.request.behavior.rawValue,
         "role": scene.request.role.rawValue, "phase": phase.rawValue,
         "completed": interactionsCompleted, "cancelled": interactionsCancelled]
    }

    private func finishInteraction(_ scene: ActiveWhiteDragonInteraction, phase: WhiteDragonInteraction.Phase, at timestamp: TimeInterval) {
        activeInteraction = nil
        effect.hide()
        sprite.pose()
        if dialoguePlayback != nil {
            endDialogueTurn(at: timestamp, outcome: .cancelled)
            lastDialogue = dialoguePlayback?.status(id: scene.request.id, phase: phase.rawValue, speaking: false)
            dialoguePlayback = nil
        } else if scene.voiceStarted {
            clearCaption()
        }
        if phase == .completed { interactionsCompleted += 1 }
        else { interactionsCancelled += 1 }
        lastInteraction = interactionStatus(scene, phase: phase)
        if working {
            mode = .working
            setAnimation("running", at: timestamp)
        } else {
            rest(at: timestamp, delay: 4)
        }
        onChange?()
    }

    private func prepareDialogue(_ dialogue: WhiteDragonDialogue, permit: WhiteDragonDialoguePermit?) -> DialoguePlayback? {
        guard let dialogueDirectory, dialogueLibrary?.contains(dialogue) == true else { return nil }
        let ownTurns = dialogue.turns.filter { $0.speaker == .dragon }
        var players: [Int: AVAudioPlayer] = [:]
        for turn in ownTurns {
            guard let player = try? AVAudioPlayer(contentsOf: dialogueDirectory.appendingPathComponent(turn.file)),
                  abs(player.duration - turn.duration) <= 0.001 else { return nil }
            if Self.silenceRecordedAudioInTests { player.volume = 0 }
            if !muted && !player.prepareToPlay() { return nil }
            player.delegate = self
            players[turn.index] = player
        }
        return DialoguePlayback(script: dialogue, ownTurns: ownTurns, players: players, permit: permit)
    }

    private func endDialogueTurn(at timestamp: TimeInterval, outcome: DialoguePlayback.Outcome) {
        guard var playback = dialoguePlayback, playback.current != nil else { return }
        let index = playback.events.count - 1
        playback.events[index].endedAt = timestamp
        playback.events[index].outcome = outcome
        dialoguePlayback = playback
        clearCaption()
    }

    private func advanceDialogue(for request: WhiteDragonInteraction, at timestamp: TimeInterval) -> Bool {
        guard var playback = dialoguePlayback else { return false }
        if let current = playback.current {
            if current.outcome == .caption, timestamp >= current.startedAt + current.turn.duration {
                voiceElapsed = current.turn.duration
                endDialogueTurn(at: timestamp, outcome: .muted)
                return true
            }
            if timestamp >= playback.deadline(for: current.turn, in: request) {
                endDialogueTurn(at: timestamp, outcome: .failed)
                cancelInteraction()
            }
            return false
        }
        guard let turn = playback.next else { return false }
        let scheduled = request.startAt + turn.offset
        guard timestamp >= scheduled else { return false }
        let deadline = playback.deadline(for: turn, in: request)
        guard timestamp <= scheduled + 0.14, timestamp + turn.duration <= deadline,
              let player = playback.players[turn.index],
              playback.permit?.allows(for: request, at: timestamp, beforeSpeech: true) != false else {
            cancelInteraction()
            return false
        }
        stopVoice()
        if !muted {
            guard player.play() else {
                cancelInteraction()
                return false
            }
            audio = player
        }
        let startedAt = now
        playback.events.append(.init(turn: turn, startedAt: startedAt, outcome: muted ? .caption : .speaking))
        dialoguePlayback = playback
        lastSpeech = turn.text
        lastSpeechSource = muted ? "muted" : "recording:\(turn.file)"
        voiceDuration = turn.duration
        voiceElapsed = 0
        displayCaption(turn.text, until: deadline)
        if startedAt > scheduled + 0.14 || startedAt + turn.duration > deadline {
            endDialogueTurn(at: now, outcome: .failed)
            cancelInteraction()
            return false
        }
        return true
    }

    private func advanceInteraction(at timestamp: TimeInterval) {
        guard var scene = activeInteraction else { return }
        let request = scene.request
        let progress = request.unitProgress(at: timestamp)
        let phase = request.phase(at: progress)
        guard phase != .completed else {
            let finished = dialoguePlayback?.finished ?? true
            finishInteraction(scene, phase: finished ? .completed : .cancelled, at: timestamp)
            return
        }
        if var permit = dialoguePlayback?.permit {
            guard permit.allows(for: request, at: timestamp) else {
                cancelInteraction()
                return
            }
            dialoguePlayback?.permit = permit
        }
        guard progress >= 0 else { return }
        let dialogueChanged = advanceDialogue(for: request, at: timestamp)
        guard activeInteraction?.request.id == request.id else { return }
        if let screen = currentScreen {
            let position = clampedOrigin(scene.position(at: progress), on: screen)
            if panel.frame.origin != position {
                panel.setFrameOrigin(position)
                if bubble.isVisible { placeBubble() }
            }
        }
        let peerOnLeft = request.peer.value.midX < panel.frame.midX
        let animation = scene.animation(at: progress, peerOnLeft: peerOnLeft)
        if animation != animationName {
            let start = request.behavior == .duet && animation == "dance"
                ? request.startAt + request.motionLength * 0.31 : timestamp
            setAnimation(animation, at: start)
        }
        let speakingLift: CGFloat
        if let turn = dialoguePlayback?.current {
            let pulse = sin(max(0, timestamp - turn.startedAt) * .pi / 0.36)
            speakingLift = 2.4 * CGFloat(pulse * pulse)
        } else {
            speakingLift = 0
        }
        drawInteractionEffect(scene, progress: progress, peerOnLeft: peerOnLeft, speakingLift: speakingLift)
        let shouldSpeak = request.dialogue == nil && request.role == .initiator && !scene.voiceStarted
            && progress >= request.voiceStart && phase != .recover
        if shouldSpeak {
            scene.voiceStarted = true
            showCaption(request.voiceLine, recording: request.behavior.rawValue, speak: true,
                        at: timestamp, directory: "Voice/Social")
        }
        let changedPhase = phase != scene.phase
        scene.phase = phase
        activeInteraction = scene
        if changedPhase || shouldSpeak || dialogueChanged { onChange?() }
    }

    private func drawInteractionEffect(_ scene: ActiveWhiteDragonInteraction, progress: Double, peerOnLeft: Bool, speakingLift: CGFloat) {
        let frame = panel.frame
        let direction: CGFloat = peerOnLeft ? -1 : 1
        let own = NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.62)
        let peer = scene.request.peer.value
        let peerHand = NSPoint(x: peer.midX, y: peer.minY + peer.height * 0.62)
        let contact = NSPoint(x: own.x + direction * frame.width * 0.44, y: own.y)
        let initiator = scene.request.role == .initiator
        var lift = speakingLift
        var stretch: CGFloat = 1
        switch scene.request.behavior {
        case .highfive where (0.40...0.70).contains(progress):
            lift += sin((progress - 0.40) / 0.30 * .pi) * 6
            if initiator, (0.50...0.65).contains(progress) {
                effect.show("💥", point: NSPoint(x: contact.x, y: contact.y + lift), progress: progress)
            } else { effect.hide() }
        case .nuzzle where (0.43...0.80).contains(progress):
            let elapsed = (progress - 0.43) / 0.37
            stretch -= CGFloat(sin(elapsed * .pi)) * 0.045
            if initiator {
                effect.show("💕", point: NSPoint(x: contact.x, y: contact.y + elapsed * 30),
                            progress: elapsed, intensity: sin(elapsed * .pi))
            }
        case .duet where (0.31...0.88).contains(progress):
            let elapsed = scene.request.motionLength * (progress - 0.31)
            let beat = abs(sin(elapsed * .pi / 0.55))
            let envelope = sin((progress - 0.31) / (0.88 - 0.31) * .pi)
            lift += frame.width * 0.055 * beat * envelope
            if initiator {
                effect.show("🎵", point: NSPoint(x: contact.x, y: frame.maxY - 10), progress: progress * 4)
            }
        case .beckon where initiator && (0.04...0.60).contains(progress):
            effect.show("✨", point: NSPoint(x: contact.x, y: own.y + 20), progress: progress * 3)
        case .starpass where initiator && (0.28...0.68).contains(progress):
            let t = (progress - 0.28) / 0.40
            let room = (currentScreen?.visibleFrame.maxY ?? max(own.y, peerHand.y) + 70) - max(own.y, peerHand.y) - 20
            let arc = min(70, max(0, room), max(25, abs(peerHand.x - own.x) * 0.16))
            let point = NSPoint(x: own.x + (peerHand.x - own.x) * t,
                                y: own.y + (peerHand.y - own.y) * t + arc * sin(t * .pi))
            effect.show("⭐️", point: point, progress: t)
        case .chase where (0.22...0.77).contains(progress):
            let toward: CGFloat = scene.destination.x < scene.origin.x ? -1 : 1
            effect.show("💨", point: NSPoint(x: own.x - toward * frame.width * 0.40,
                                            y: frame.minY + frame.height * 0.28),
                        progress: progress * 5, intensity: 0.65)
        default:
            effect.hide()
        }
        sprite.pose(lift: lift, stretch: stretch)
    }

    var observation: [String: Any] {
        let frame = panel.frame
        var state: [String: Any] = [
            "visible": panel.isVisible,
            "windowNumber": panel.windowNumber,
            "working": working,
            "roaming": roaming,
            "muted": muted,
            "mode": mode.rawValue,
            "animation": animationName,
            "frameIndex": displayIndex ?? -1,
            "position": ["x": Double(frame.minX), "y": Double(frame.minY)],
            "size": ["width": Double(frame.width), "height": Double(frame.height)],
            "walksStarted": walksStarted,
            "walksFinished": walksFinished,
            "passesMouseEvents": panel.ignoresMouseEvents,
            "messageVisible": bubble.isVisible,
            "lastMessage": lastSpeech,
            "lastVoiceSource": lastSpeechSource,
            "isSpeaking": audio?.isPlaying == true || synthesizer.isSpeaking,
            "animationFrames": animations.mapValues { $0.frames.count },
            "social": social,
            "nativeEncounter": encounter?.phase.rawValue ?? "none",
            "nativeVisitsStarted": nativeVisitsStarted,
            "nativeVisitsFinished": nativeVisitsFinished,
            "nativeHandoffs": nativeHandoffs
        ]
        state["expressionPanel"] = expressions.status
        state["lastSpeechSource"] = lastSpeechSource
        state["voicePlaying"] = audio?.isPlaying == true
        state["voiceDuration"] = voiceDuration
        state["voiceElapsed"] = max(voiceElapsed, audio?.currentTime ?? 0)
        state["selectedExpression"] = selectedExpression?.rawValue as Any? ?? NSNull()
        state["lastExpression"] = lastExpression?.rawValue as Any? ?? NSNull()
        state["effectVisible"] = effect.visible
        state["effect"] = effect.name as Any? ?? NSNull()
        state["interactionReady"] = interactionReady
        state["interactionCompleted"] = interactionsCompleted
        state["interactionCancelled"] = interactionsCancelled
        state["interaction"] = activeInteraction.map { interactionStatus($0, phase: $0.phase) } as Any? ?? NSNull()
        state["lastInteraction"] = lastInteraction as Any? ?? NSNull()
        state["dialogue"] = activeInteraction.flatMap { scene in
            dialoguePlayback?.status(id: scene.request.id, phase: "active", speaking: audio?.isPlaying == true)
        } as Any? ?? NSNull()
        state["lastDialogue"] = lastDialogue as Any? ?? NSNull()
        state["nativeVisitUnavailableReason"] = nativeVisitUnavailableReason
        state["lastNativeVisitTrigger"] = lastNativeVisitTrigger
        if let nativePet {
            state["nativePet"] = [
                "x": Double(nativePet.minX), "y": Double(nativePet.minY),
                "width": Double(nativePet.width), "height": Double(nativePet.height)
            ]
        }
        if let lastWalkStart, let lastWalkDestination, let lastWalkAnimation {
            state["lastWalk"] = [
                "start": ["x": Double(lastWalkStart.x), "y": Double(lastWalkStart.y)],
                "destination": ["x": Double(lastWalkDestination.x), "y": Double(lastWalkDestination.y)],
                "animation": lastWalkAnimation
            ]
        }
        if let screen = currentScreen {
            let area = screen.visibleFrame
            state["screen"] = [
                "x": Double(area.minX), "y": Double(area.minY),
                "width": Double(area.width), "height": Double(area.height)
            ]
        }
        return state
    }

    private static func loadAnimations(_ resources: URL?) -> [String: PetAnimation] {
        guard let base = resources?.appendingPathComponent("Frames", isDirectory: true) else {
            return [:]
        }
        return frameLengths.reduce(into: [:]) { result, entry in
            let (name, frameLengths) = entry
            let directory = base.appendingPathComponent(name, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            let frames = urls.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .compactMap(PetFrame.init)
            if !frames.isEmpty {
                result[name] = PetAnimation(frames: frames, frameLengths: frameLengths)
            }
        }
    }

    private func tick() {
        let timestamp = now
        let elapsed = min(timestamp - lastTick, 0.075)
        lastTick = timestamp
        if bubbleUntil > 0 && timestamp >= bubbleUntil {
            bubble.orderOut(nil)
            bubbleUntil = 0
        }
        if activeInteraction != nil {
            advanceInteraction(at: timestamp)
        } else if let expression = selectedExpression {
            if timestamp >= standUntil {
                endExpression()
                if working {
                    mode = .working
                    setAnimation("running", at: timestamp)
                } else {
                    rest(at: timestamp)
                }
                onChange?()
            } else {
                drawExpressionEffect(expression, at: timestamp)
            }
        } else if gesture == nil, !expressions.window.isVisible {
            checkNativeDrag(at: timestamp)
            if !working && roaming && encounter == nil && (mode == .idle || mode == .walking) {
                startSeparationIfNeeded(at: timestamp)
            }
            if encounter != nil {
                advanceEncounter(at: timestamp, elapsed: elapsed)
            } else if !working, walk != nil {
                move(at: timestamp, elapsed: elapsed)
            } else if !working, (mode == .deliberate || mode == .ambient), timestamp >= standUntil {
                rest(at: timestamp)
            } else if !working, mode == .idle, roaming, hoverStarted == nil, timestamp >= nextBehavior {
                startNextBehavior(at: timestamp)
            }
        }
        drawFrame(at: timestamp)
        updateMouseTarget()
    }

    private func setAnimation(_ requested: String, at timestamp: TimeInterval) {
        animationName = animations[requested] != nil ? requested : "idle"
        animationStart = timestamp
        displayIndex = nil
    }

    private func drawFrame(at timestamp: TimeInterval) {
        guard let animation = animations[animationName] else { return }
        let index = animation.index(at: timestamp - animationStart)
        guard displayIndex != index else { return }
        displayIndex = index
        sprite.sprite = animation.frames[index]
        sprite.needsDisplay = true
    }

    private func rest(at timestamp: TimeInterval, delay: TimeInterval? = nil) {
        let wasWalking = mode == .walking || mode == .separating
        walk = nil
        mode = .idle
        setAnimation("idle", at: timestamp)
        nextBehavior = timestamp + (delay ?? .random(in: 3.5...6.0))
        if wasWalking { onChange?() }
    }

    private func startNextBehavior(at timestamp: TimeInterval) {
        guard !panel.frame.insetBy(dx: -15, dy: -15).contains(NSEvent.mouseLocation) else {
            nextBehavior = timestamp + 3
            return
        }
        if social, let nativePet, timestamp >= nextNativeVisit, bubbleUntil == 0 {
            if startEncounter(with: nativePet, trigger: .idle, at: timestamp) { return }
            nextNativeVisit = timestamp + 8
        }
        if walkNext, let screen = currentScreen, let destination = destination(on: screen) {
            startWalk(to: destination, at: timestamp)
            walkNext = false
            return
        }

        let name = Self.ambientAnimations[ambientIndex]
        ambientIndex = (ambientIndex + 1) % Self.ambientAnimations.count
        mode = .ambient
        setAnimation(name, at: timestamp)
        let duration = animations[name]?.duration ?? 1
        standUntil = timestamp + (name == "dance" ? duration * 2 : duration)
        walkNext = true
    }

    private func destination(on screen: NSScreen) -> NSPoint? {
        let allowed = origins(on: screen)
        let origin = panel.frame.origin
        let pointer = NSEvent.mouseLocation
        let minX = max(allowed.minX, origin.x - 520)
        let maxX = min(allowed.maxX, origin.x + 520)
        let minY = max(allowed.minY, origin.y - 250)
        let maxY = min(allowed.maxY, origin.y + 250)
        let minHorizontalChange = min(100, allowed.width * 0.25)
        let minVerticalChange = min(75, allowed.height * 0.25)
        guard minX < maxX, minY < maxY else { return nil }
        for _ in 0..<30 {
            let candidate = NSPoint(x: .random(in: minX...maxX), y: .random(in: minY...maxY))
            let target = NSRect(origin: candidate, size: size)
            if abs(candidate.x - origin.x) >= minHorizontalChange,
               abs(candidate.y - origin.y) >= minVerticalChange,
               !target.insetBy(dx: -60, dy: -60).contains(pointer),
               nativePet.map({ routeClears($0, from: origin, to: candidate) }) ?? true {
                return candidate
            }
        }
        return nil
    }

    private func startWalk(to destination: NSPoint, at timestamp: TimeInterval) {
        let route = PetWalk(start: panel.frame.origin, destination: destination)
        walk = route
        walksStarted += 1
        lastWalkStart = route.start
        lastWalkDestination = destination
        lastWalkAnimation = route.animation
        mode = .walking
        setAnimation(route.animation, at: timestamp)
        onChange?()
    }

    private func startSeparationIfNeeded(at timestamp: TimeInterval) {
        guard let target = nativePet, panel.frame.intersects(target), let screen = currentScreen else { return }
        if mode == .walking { rest(at: timestamp) }
        let released = nativeDragReleasedAt.map { timestamp - $0 >= 0.28 } ?? !draggedNativePet
        guard released, NSEvent.pressedMouseButtons == 0 else { return }
        let origin = panel.frame.origin
        let pointer = NSEvent.mouseLocation
        let pointerAtStart = panel.frame.insetBy(dx: -12, dy: -12).contains(pointer)
        let gap: CGFloat = 12
        let exits = [
            NSPoint(x: target.minX - size.width - gap, y: origin.y),
            NSPoint(x: target.maxX + gap, y: origin.y),
            NSPoint(x: origin.x, y: target.minY - size.height - gap),
            NSPoint(x: origin.x, y: target.maxY + gap),
        ].map { clampedOrigin($0, on: screen) }
        let destination = exits.filter { point in
            let frame = NSRect(origin: point, size: size)
            let swept = frame.union(panel.frame).insetBy(dx: -12, dy: -12)
            return !frame.intersects(target) && !frame.insetBy(dx: -12, dy: -12).contains(pointer)
                && (pointerAtStart || !swept.contains(pointer))
        }.min { a, b in
            hypot(a.x - origin.x, a.y - origin.y) < hypot(b.x - origin.x, b.y - origin.y)
        }
        guard let destination else { return }
        startWalk(to: destination, at: timestamp)
        mode = .separating
    }

    private func move(at timestamp: TimeInterval, elapsed: TimeInterval) {
        guard var route = walk else { return }
        route.elapsed += elapsed
        let position = route.position
        let nextFrame = NSRect(origin: position, size: size)
        let pointer = NSEvent.mouseLocation
        let crossesPointer = nextFrame.insetBy(dx: -12, dy: -12).contains(pointer)
        let separating = mode == .separating
        let leavingPointer = (separating || encounter?.trigger == .menu)
            && panel.frame.insetBy(dx: -12, dy: -12).contains(pointer)
        let blockedByNative = nativePet.map { target in
            // An escape may traverse the overlap where it started, then gives way as usual.
            target.intersects(nextFrame) && !(separating && target.intersects(panel.frame))
        } ?? false
        if (crossesPointer && !leavingPointer) || blockedByNative || (separating && NSEvent.pressedMouseButtons != 0) {
            if encounter != nil { endEncounter(at: timestamp) }
            else { rest(at: timestamp, delay: 6) }
            return
        }
        panel.setFrameOrigin(position)
        if route.arrived {
            walksFinished += 1
            walk = nil
            if encounter != nil {
                greetNative(at: timestamp)
            } else {
                rest(at: timestamp)
            }
        } else {
            walk = route
        }
    }

    private func nativeShift(from old: NSRect, to new: NSRect) -> CGFloat {
        max(abs(old.minX - new.minX), abs(old.minY - new.minY),
            abs(old.maxX - new.maxX), abs(old.maxY - new.maxY))
    }

    private func gapBetween(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let x = max(0, first.minX - second.maxX, second.minX - first.maxX)
        let y = max(0, first.minY - second.maxY, second.minY - first.maxY)
        return hypot(x, y)
    }

    private func routeClears(_ target: NSRect, from start: NSPoint, to end: NSPoint) -> Bool {
        // The moving window intersects the native window only while its origin is inside this region.
        let blocked = NSRect(x: target.minX - size.width, y: target.minY - size.height,
                             width: target.width + size.width, height: target.height + size.height)
        func crossing(_ first: CGFloat, _ last: CGFloat, _ low: CGFloat, _ high: CGFloat) -> ClosedRange<CGFloat>? {
            if first == last { return first > low && first < high ? (-CGFloat.infinity)...CGFloat.infinity : nil }
            let a = (low - first) / (last - first)
            let b = (high - first) / (last - first)
            return min(a, b)...max(a, b)
        }
        guard let x = crossing(start.x, end.x, blocked.minX, blocked.maxX),
              let y = crossing(start.y, end.y, blocked.minY, blocked.maxY) else { return true }
        return max(0, x.lowerBound, y.lowerBound) >= min(1, x.upperBound, y.upperBound)
    }

    private func encounterDestination(for target: NSRect, on screen: NSScreen) -> NSPoint? {
        let origin = panel.frame.origin
        let gap: CGFloat = 12
        let feet = target.minY + max(0, target.height - size.height) * 0.14
        let center = target.midX - size.width / 2
        let candidates = [
            NSPoint(x: target.minX - size.width - gap, y: feet),
            NSPoint(x: target.maxX + gap, y: feet),
            NSPoint(x: center, y: target.minY - size.height - gap),
            NSPoint(x: center, y: target.maxY + gap),
        ]
        return candidates.enumerated().compactMap { index, point -> (NSPoint, CGFloat)? in
            let candidate = clampedOrigin(point, on: screen)
            let frame = NSRect(origin: candidate, size: size)
            guard !frame.intersects(target), gapBetween(frame, target) >= 5,
                  routeClears(target, from: origin, to: candidate) else { return nil }
            let distance = hypot(candidate.x - origin.x, candidate.y - origin.y)
            return (candidate, distance + (index > 1 ? 125 : 0))
        }.min { $0.1 < $1.1 }?.0
    }

    private func startEncounter(with target: NSRect, trigger: EncounterTrigger, at timestamp: TimeInterval) -> Bool {
        guard social, panel.isVisible, gesture == nil, let screen = currentScreen,
              activeInteraction == nil, !expressions.window.isVisible, selectedExpression == nil,
              screen.frame.contains(NSPoint(x: target.midX, y: target.midY)),
              !panel.frame.intersects(target) else { return false }
        if trigger != .menu {
            guard !working, roaming, encounter == nil, bubbleUntil == 0, !draggedNativePet else { return false }
        }
        let destination: NSPoint
        if working || !roaming {
            destination = panel.frame.origin
        } else {
            guard let next = encounterDestination(for: target, on: screen) else { return false }
            destination = next
        }
        endEncounter(at: timestamp)
        if trigger == .menu && bubbleUntil > 0 { clearCaption() }
        encounter = Encounter(trigger: trigger, dance: nativeHandoffs % 2 == 1, target: target)
        nativeVisitsStarted += 1
        lastNativeVisitTrigger = trigger.rawValue
        nextNativeVisit = timestamp + .random(in: 55...95)
        if hypot(destination.x - panel.frame.minX, destination.y - panel.frame.minY) > 3 {
            startWalk(to: destination, at: timestamp)
        } else {
            walk = nil
            greetNative(at: timestamp)
        }
        return true
    }

    private func advanceEncounter(at timestamp: TimeInterval, elapsed: TimeInterval) {
        guard var encounter, let nativePet else { return }
        switch encounter.phase {
        case .approaching:
            if nativeShift(from: encounter.target, to: nativePet) >= 12 {
                guard let screen = currentScreen,
                      screen.frame.contains(NSPoint(x: nativePet.midX, y: nativePet.midY)),
                      let destination = encounterDestination(for: nativePet, on: screen) else {
                    endEncounter(at: timestamp)
                    return
                }
                encounter.target = nativePet
                self.encounter = encounter
                startWalk(to: destination, at: timestamp)
            }
            move(at: timestamp, elapsed: elapsed)
        case .greeting:
            guard timestamp >= encounter.until else { return }
            encounter.phase = .waiting
            encounter.until = timestamp + 1.2
            self.encounter = encounter
            if !working { setAnimation("waiting", at: timestamp) }
        case .waiting:
            guard timestamp >= encounter.until else { return }
            nativeVisitsFinished += 1
            endEncounter(at: timestamp)
        }
    }

    private func greetNative(at timestamp: TimeInterval) {
        guard var encounter, let target = nativePet else { endEncounter(at: timestamp); return }
        guard !panel.frame.intersects(target) else { endEncounter(at: timestamp); return }
        let dance = encounter.dance && !working && roaming
        if !working {
            mode = .visiting
            setAnimation(dance ? "dance" : "waving", at: timestamp)
        }
        let line = dance ? "白龙，一起来跳舞吧！" : "白龙，接住这颗星星！"
        showCaption(line, recording: dance ? "star_dance" : "star_catch",
                    speak: encounter.trigger == .menu && !working, at: timestamp)
        encounter.phase = .greeting
        encounter.target = target
        encounter.until = bubbleUntil
        self.encounter = encounter
        nativeHandoffs += 1
        onStarPass?(panel.frame, target)
    }

    private func endEncounter(at timestamp: TimeInterval) {
        guard let encounter else { return }
        self.encounter = nil
        if encounter.phase != .approaching { clearCaption() }
        onStarPassEnd?()
        if !working { rest(at: timestamp, delay: 6) }
        else { walk = nil }
    }

    private func checkNativeDrag(at timestamp: TimeInterval) {
        guard draggedNativePet, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let releaseTime = nativeDragReleasedAt ?? timestamp
        nativeDragReleasedAt = releaseTime
        let sinceRelease = timestamp - releaseTime
        guard sinceRelease >= 0.28 else { return }
        let stillSeparating = mode == .separating || nativePet?.intersects(panel.frame) == true
        if stillSeparating && sinceRelease < 6 { return }
        draggedNativePet = false
        nativeDragReleasedAt = nil
        if !stillSeparating, let nativePet, gapBetween(panel.frame, nativePet) <= 95,
           timestamp >= nextNativeDragGreeting, startEncounter(with: nativePet, trigger: .nativeDrag, at: timestamp) {
            nextNativeDragGreeting = timestamp + 20
        }
    }

    private func perform(_ message: String, animation: String, recording: String?, expression: WhiteDragonExpression? = nil) {
        let cleanLine = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLine.isEmpty else { return }
        show()
        guard panel.isVisible else { return }
        let timestamp = now
        dismissExpressions()
        cancelInteraction()
        endExpression()
        endEncounter(at: timestamp)
        walk = nil
        if !working || expression != nil {
            mode = .deliberate
            setAnimation(animation, at: timestamp)
            standUntil = timestamp + max(3.7, animations[animation]?.duration ?? 0)
        }
        if let expression {
            selectedExpression = expression
            lastExpression = expression
            expressionStart = timestamp
        }
        showCaption(cleanLine, recording: recording, speak: true, at: timestamp,
                    directory: expression.map { $0 == .water || $0 == .stretch ? "Care" : "Voice" })
        if !working || expression != nil { standUntil = max(standUntil, bubbleUntil) }
        onChange?()
    }

    private func endExpression() {
        guard selectedExpression != nil else { return }
        selectedExpression = nil
        effect.hide()
        sprite.pose()
    }

    private func drawExpressionEffect(_ expression: WhiteDragonExpression, at timestamp: TimeInterval) {
        let t = max(0, min(1, (timestamp - expressionStart) / (standUntil - expressionStart)))
        let accent = sin(t * .pi)
        let pet = panel.frame
        var point = NSPoint(x: pet.midX + pet.width * 0.30, y: pet.maxY - 21)
        switch expression {
        case .greeting: return
        case .dance:
            point.y += 6 * sin(t * .pi * 4)
        case .playful:
            point.y += 15 * accent
        case .cheer:
            sprite.pose(lift: 3 * accent)
            point.y += 16 * accent
        case .shy:
            sprite.pose(stretch: 1 - 0.04 * accent)
            point.y -= 10 * accent
        case .sleepy:
            sprite.pose(stretch: 1 - 0.10 * accent)
            point.y += 8 * sin(t * .pi * 2)
        case .water:
            point.x = pet.midX + pet.width * (0.18 - 0.12 * accent)
            point.y = pet.minY + pet.height * (0.42 + 0.17 * accent)
        case .stretch:
            sprite.pose(stretch: 1 + 0.09 * accent)
            point.y += 8 * accent
        }
        if let symbol = expression.effect {
            effect.show(symbol, point: point, progress: t, intensity: min(1, 2.5 * accent))
        }
    }

    private func clearCaption() {
        bubble.orderOut(nil)
        bubbleUntil = 0
        stopVoice()
    }

    private func showCaption(_ line: String, recording: String?, speak: Bool, at timestamp: TimeInterval, directory: String? = nil) {
        lastSpeech = line
        let voiceDuration: TimeInterval
        if speak {
            voiceDuration = voice(line, recording: recording, directory: directory)
        } else {
            lastSpeechSource = muted ? "muted" : "caption"
            self.voiceDuration = 0
            voiceElapsed = 0
            voiceDuration = 0
        }
        let readDuration = Double(line.count) * 0.19 + 0.75
        displayCaption(line, until: timestamp + max(3.2, readDuration, voiceDuration + 0.75))
    }

    private func displayCaption(_ line: String, until: TimeInterval) {
        let maximumWidth = max(100, min(240, (currentScreen?.visibleFrame.width ?? 270) - 30))
        let view = PetBubbleView(line, maximumWidth: maximumWidth)
        bubble.contentView = view
        bubble.setContentSize(view.frame.size)
        bubbleUntil = until
        placeBubble()
        bubble.orderFrontRegardless()
    }

    @discardableResult
    private func voice(_ message: String, recording: String?, directory: String? = nil) -> TimeInterval {
        stopVoice()
        voiceDuration = 0
        voiceElapsed = 0
        if muted {
            lastSpeechSource = "muted"
            return 0
        }
        if let recording, let resourceURL {
            for directory in directory.map({ [$0] }) ?? ["Care", "Voice"] {
                let url = resourceURL.appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(recording).appendingPathExtension("wav")
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    player.delegate = self
                    if Self.silenceRecordedAudioInTests { player.volume = 0 }
                    guard player.play() else { continue }
                    audio = player
                    voiceDuration = player.duration
                    lastSpeechSource = "recording:\(recording)"
                    return player.duration
                }
            }
        }
        guard !Self.silenceRecordedAudioInTests, let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            lastSpeechSource = "unavailable"
            return 0
        }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synthesizer.speak(utterance)
        lastSpeechSource = "system:zh-CN"
        return Double(message.count) * 0.23 + 0.4
    }

    private func stopVoice() {
        if let audio {
            voiceElapsed = max(voiceElapsed, audio.currentTime)
            audio.stop()
        }
        audio = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard audio === player else { return }
        voiceElapsed = flag ? player.duration : max(voiceElapsed, player.currentTime)
        audio = nil
        if dialoguePlayback?.current != nil {
            endDialogueTurn(at: now, outcome: flag ? .completed : .failed)
            if !flag {
                cancelInteraction()
                return
            }
        }
        onChange?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard audio === player, dialoguePlayback?.current != nil else { return }
        endDialogueTurn(at: now, outcome: .failed)
        cancelInteraction()
    }

    private func placeBubble() {
        guard bubble.contentView is PetBubbleView,
              let screen = currentScreen else { return }
        let pet = panel.frame
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = bubble.frame.width
        let height = bubble.frame.height
        let x = min(max(pet.midX - width / 2, visible.minX), visible.maxX - width)
        let above = pet.maxY + 3
        let y = above + height <= visible.maxY ? above : max(visible.minY, pet.minY - height - 3)
        bubble.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func origins(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        return NSRect(
            x: visible.minX, y: visible.minY,
            width: max(0, visible.width - size.width),
            height: max(0, visible.height - size.height)
        )
    }

    private func clampedOrigin(_ origin: NSPoint, on screen: NSScreen) -> NSPoint {
        let allowed = origins(on: screen)
        return NSPoint(
            x: min(max(origin.x, allowed.minX), allowed.maxX),
            y: min(max(origin.y, allowed.minY), allowed.maxY)
        )
    }

    private func placeOnScreen() {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
        if placed, let screen = currentScreen {
            panel.setFrameOrigin(clampedOrigin(panel.frame.origin, on: screen))
            return
        }
        guard let screen = pointerScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            placed = false
            return
        }
        screenID = screenNumber(screen)
        let allowed = origins(on: screen)
        panel.setFrameOrigin(NSPoint(x: allowed.maxX - min(26, allowed.width), y: allowed.minY))
        placed = true
    }

    @discardableResult
    func restorePosition(_ origin: NSPoint) -> Bool {
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return false }
        screenID = screenNumber(screen)
        panel.setFrameOrigin(clampedOrigin(origin, on: screen))
        placed = true
        return true
    }

    @objc private func displaysChanged() {
        cancelInteraction()
        endEncounter(at: now)
        draggedNativePet = false
        nativeDragReleasedAt = nil
        walk = nil
        if mode == .walking || mode == .separating { rest(at: now, delay: 5) }
        placeOnScreen()
        if bubble.isVisible { placeBubble() }
        if expressions.window.isVisible { expressions.show(near: panel.frame, on: currentScreen) }
    }

    private func updateMouseTarget() {
        if gesture != nil { return }
        let frame = panel.frame
        let mouse = NSEvent.mouseLocation
        let point = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let hitsSprite = sprite.sprite?.acceptsClick(point, in: sprite.imageBounds) ?? false
        updateExpressions(at: mouse, onBody: hitsSprite)
        if panel.ignoresMouseEvents == hitsSprite {
            panel.ignoresMouseEvents = !hitsSprite
        }
    }

    private func dismissExpressions() {
        hoverStarted = nil
        pinnedExpressions = false
        needsHoverExit = true
        expressions.hide()
    }

    private func pauseRoamingForExpressions() {
        endEncounter(at: now)
        if walk != nil { rest(at: now, delay: 3) }
    }

    private func movingBetweenPetAndPanel(_ point: NSPoint) -> Bool {
        let box = expressions.window.frame
        let edge = box.midX > panel.frame.midX ? box.minX : box.maxX
        let length = edge - lastBodyPoint.x
        guard abs(length) > 1, point != previousPointer else { return false }
        let offset = (point.x - lastBodyPoint.x) / length
        guard (0...1).contains(offset) else { return false }
        let bottom = lastBodyPoint.y + (box.minY - lastBodyPoint.y) * offset - 7
        let top = lastBodyPoint.y + (box.maxY - lastBodyPoint.y) * offset + 7
        return (bottom...top).contains(point.y)
    }

    private func updateExpressions(at point: NSPoint, onBody: Bool) {
        defer { previousPointer = point }
        guard panel.isVisible, activeInteraction == nil, !pinnedExpressions else { return }
        let timestamp = now
        if expressions.window.isVisible {
            if onBody { lastBodyPoint = point }
            if onBody || expressions.window.frame.contains(point) || movingBetweenPetAndPanel(point) {
                hoverHideAfter = timestamp + 0.4
            } else if timestamp >= hoverHideAfter {
                expressions.hide()
            }
            return
        }
        guard onBody else {
            hoverStarted = nil
            needsHoverExit = false
            return
        }
        guard !needsHoverExit else { return }
        let start = hoverStarted ?? timestamp
        hoverStarted = start
        pauseRoamingForExpressions()
        guard timestamp - start >= 0.16 else { return }
        hoverStarted = nil
        lastBodyPoint = point
        hoverHideAfter = timestamp + 0.4
        expressions.show(near: panel.frame, on: currentScreen)
    }

    private func press(at position: NSPoint) {
        dismissExpressions()
        gesture = Gesture(mouseStart: position, windowStart: panel.frame.origin)
        cancelInteraction()
        onChange?()
    }

    private func drag(to position: NSPoint) {
        guard var gesture else { return }
        let dx = position.x - gesture.mouseStart.x
        let dy = position.y - gesture.mouseStart.y
        guard gesture.dragged || hypot(dx, dy) >= 4 else { return }
        if !gesture.dragged {
            gesture.dragged = true
            self.gesture = gesture
            endEncounter(at: now)
            endExpression()
            clearCaption()
            walk = nil
            if !working {
                mode = .dragging
                setAnimation("idle", at: now)
            }
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(position) }) ?? currentScreen {
            screenID = screenNumber(screen)
            let origin = NSPoint(x: gesture.windowStart.x + dx, y: gesture.windowStart.y + dy)
            panel.setFrameOrigin(clampedOrigin(origin, on: screen))
            if bubble.isVisible { placeBubble() }
        }
    }

    private func release(at _: NSPoint) {
        guard let gesture else { return }
        self.gesture = nil
        if gesture.dragged {
            if !working { rest(at: now, delay: 8) }
        } else {
            play("greeting")
        }
        updateMouseTarget()
        onChange?()
    }
}
