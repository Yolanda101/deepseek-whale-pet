import AppKit
import QuartzCore

private struct WhaleInteractionDialogue {
    struct Playback {
        enum Outcome: String { case completed, muted, cancelled, failed }

        let recording: WhaleDialogueRecording
        let startedAt: TimeInterval
        var endedAt: TimeInterval?
        var outcome: Outcome?

        var turn: WhaleDialogueRequest.Turn { recording.turn }
        var report: [String: Any] {
            ["index": turn.index, "speaker": turn.speaker.rawValue, "text": turn.text, "file": turn.file,
             "startedAt": startedAt, "endedAt": endedAt as Any? ?? NSNull(),
             "completedAt": (outcome == .completed ? endedAt : nil) as Any? ?? NSNull(),
             "outcome": outcome?.rawValue as Any? ?? NSNull()]
        }
    }

    let id: UUID
    let script: String
    let recordings: [WhaleDialogueRecording]
    var played: [Playback] = []

    var current: Playback? { played.last.flatMap { $0.endedAt == nil ? $0 : nil } }
    var next: WhaleDialogueRecording? { played.count < recordings.count ? recordings[played.count] : nil }
    var allTurnsFinished: Bool { current == nil && next == nil }

    mutating func endTurn(at time: TimeInterval, outcome: Playback.Outcome) {
        guard current != nil else { return }
        played[played.count - 1].endedAt = time
        played[played.count - 1].outcome = outcome
    }

    func report(phase: String) -> [String: Any] {
        let current = self.current
        return ["id": id.uuidString, "script": script, "phase": phase,
                "currentTurn": current?.turn.index as Any? ?? NSNull(),
                "speaker": current?.turn.speaker.rawValue as Any? ?? NSNull(),
                "speaking": current != nil,
                "completedTurns": played.filter { $0.outcome == .completed || $0.outcome == .muted }.map { $0.turn.index },
                "turns": played.map(\.report)]
    }
}

private struct WhaleInteractionScene {
    enum Phase: String {
        case waiting, approach, perform, recover
    }

    struct Step {
        let phase: Phase
        let pose: Pose
        let origin: NSPoint
        let poseStart: TimeInterval
    }

    let request: WhaleInteraction
    let origin: NSPoint
    let destination: NSPoint
    let display: NSRect

    private var initiator: Bool { request.role == .initiator }
    private var walk: Pose { destination.x < origin.x ? .walkLeft : .walkRight }

    func direction(from frame: NSRect) -> CGFloat { request.peer.frame.midX < frame.midX ? -1 : 1 }
    func progress(at time: TimeInterval) -> Double { min(1, (time - request.startAt) / request.movementDuration) }

    var voiceCue: (event: String, progress: Double)? {
        guard initiator else { return nil }
        switch request.behavior {
        case .highfive: return ("greeting", 0.38)
        case .duet: return ("dance", 0.31)
        case .beckon: return ("outing", 0.04)
        case .chase: return ("outing", 0.08)
        case .nuzzle, .starpass: return nil
        }
    }

    func step(at progress: Double, width: CGFloat) -> Step {
        guard progress >= 0 else { return Step(phase: .waiting, pose: .idle, origin: origin, poseStart: 0) }
        let start: Double
        let finish: Double
        let recover: Double
        let action: Pose
        let lift: CGFloat
        let lean: CGFloat
        switch request.behavior {
        case .highfive:
            (start, finish, recover, action) = (0, 0.36, 0.84, .greeting)
            lift = width * 0.17 * pulse(progress, from: 0.40, to: 0.70)
            lean = 0
        case .nuzzle:
            (start, finish, recover, action) = (0, 0.38, 0.84, .playful)
            lift = width * 0.025 * pulse(progress, from: 0.44, to: 0.80)
            lean = width * 0.065 * pulse(progress, from: 0.41, to: 0.83)
        case .duet:
            (start, finish, recover, action) = (0, 0.31, 0.88, .dance)
            let dance = request.movementDuration * (progress - finish)
            let beat = abs(sin(dance * .pi / 0.55))
            lift = width * 0.055 * beat * pulse(progress, from: finish, to: recover)
            lean = 0
        case .beckon:
            (start, finish, recover, action) = (0.24, 0.65, 0.86, .greeting)
            lift = initiator ? 0 : width * 0.065 * stride(progress, from: start, to: finish)
            lean = 0
        case .starpass:
            (start, finish, recover) = (0, initiator ? 0.14 : 0.62, 0.88)
            action = initiator ? .greeting : .feeding
            lift = width * 0.070 * pulse(progress, from: initiator ? 0.2 : 0.61, to: initiator ? 0.4 : 0.80)
            lean = 0
        case .chase:
            (start, finish, recover, action) = initiator ? (0.08, 0.74, 0.88, .playful) : (0.16, 0.78, 0.88, .playful)
            lift = width * 0.08 * stride(progress, from: start, to: finish)
            lean = 0
        }
        let portion = fraction(progress, from: start, to: finish)
        let eased = portion * portion * (3 - 2 * portion)
        let side: CGFloat = request.peer.frame.midX < origin.x + width / 2 ? -1 : 1
        let position = NSPoint(x: origin.x + (destination.x - origin.x) * eased + lean * side,
                               y: origin.y + (destination.y - origin.y) * eased + lift)
        if progress >= recover { return Step(phase: .recover, pose: .idle, origin: position, poseStart: recover) }
        if request.behavior == .beckon && initiator {
            return Step(phase: .perform, pose: .greeting, origin: position, poseStart: 0)
        }
        if progress >= finish { return Step(phase: .perform, pose: action, origin: position, poseStart: finish) }
        if progress >= start, origin != destination {
            return Step(phase: .approach, pose: walk, origin: position, poseStart: start)
        }
        return Step(phase: .perform, pose: .idle, origin: position, poseStart: 0)
    }

    func effect(at progress: Double, frame: NSRect) -> WhaleInteractionMark? {
        guard progress >= 0 else { return nil }
        let side = direction(from: frame)
        let local = NSPoint(x: frame.midX + side * frame.width * 0.30, y: frame.minY + frame.height * 0.70)
        switch request.behavior {
        case .highfive:
            guard initiator, (0.49...0.68).contains(progress) else { return nil }
            return .init(kind: .burst, point: local, age: fraction(progress, from: 0.49, to: 0.68), side: side)
        case .nuzzle:
            guard initiator, (0.43...0.80).contains(progress) else { return nil }
            let age = fraction(progress, from: 0.43, to: 0.80)
            let point = NSPoint(x: local.x, y: frame.minY + frame.height * 0.80 + 16 * age)
            return .init(kind: .heart, point: point, age: age, side: side)
        case .duet:
            guard (0.32...0.88).contains(progress) else { return nil }
            let beat = (request.movementDuration * (progress - 0.32) / 0.75).truncatingRemainder(dividingBy: 1)
            let point = NSPoint(x: frame.midX - side * frame.width * 0.35, y: local.y + 9 * beat)
            return .init(kind: .note, point: point, age: beat, side: -side)
        case .beckon:
            guard initiator, (0.06...0.58).contains(progress) else { return nil }
            let age = (request.movementDuration * (progress - 0.06) / 0.85).truncatingRemainder(dividingBy: 1)
            return .init(kind: .wave, point: local, age: age, side: side)
        case .starpass:
            guard initiator, (0.28...0.84).contains(progress) else { return nil }
            let peer = request.peer.frame
            let end = NSPoint(x: peer.midX, y: peer.minY + peer.height * 0.65)
            if progress >= 0.68 {
                return .init(kind: .burst, point: end, age: fraction(progress, from: 0.68, to: 0.84), side: side)
            }
            let start = NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.65)
            let age = fraction(progress, from: 0.28, to: 0.68)
            let distance = hypot(end.x - start.x, end.y - start.y)
            let room = max(0, display.maxY - 20 - max(start.y, end.y))
            let arc = min(85, distance * 0.30, room)
            let point = NSPoint(x: start.x + (end.x - start.x) * age,
                                y: start.y + (end.y - start.y) * age + arc * sin(age * .pi))
            return .init(kind: .star, point: point, age: age, side: side)
        case .chase:
            let start = initiator ? 0.08 : 0.16
            let finish = initiator ? 0.74 : 0.78
            guard (start...finish).contains(progress) else { return nil }
            let age = (request.movementDuration * (progress - start) / 0.50).truncatingRemainder(dividingBy: 1)
            let travelSide: CGFloat = destination.x < origin.x ? -1 : 1
            let point = NSPoint(x: frame.midX - travelSide * frame.width * 0.36, y: frame.minY + frame.height * 0.27)
            return .init(kind: .dash, point: point, age: age, side: travelSide)
        }
    }

    private func fraction(_ progress: Double, from start: Double, to end: Double) -> Double {
        min(1, max(0, (progress - start) / (end - start)))
    }

    private func pulse(_ progress: Double, from start: Double, to end: Double) -> Double {
        guard (start...end).contains(progress) else { return 0 }
        return sin(fraction(progress, from: start, to: end) * .pi)
    }

    private func stride(_ progress: Double, from start: Double, to end: Double) -> Double {
        let t = fraction(progress, from: start, to: end)
        return abs(sin(t * .pi * 5)) * sin(t * .pi)
    }
}

private struct WhaleInteractionMark {
    enum Kind: String { case burst, heart, note, wave, star, dash }
    let kind: Kind
    let point: NSPoint
    let age: CGFloat
    let side: CGFloat
}

private final class WhaleInteractionEffect {
    private let view = WhaleInteractionEffectView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
    private lazy var panel: PetPanel = {
        let window = PetPanel(overlaySize: view.frame.size, title: "大肥鱼互动特效")
        window.contentView = view
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .floating + 1
        return window
    }()

    var isShowing: Bool { view.mark != nil }
    var name: String? { view.mark?.kind.rawValue }
    var position: NSPoint? { view.mark?.point }

    func render(_ sample: WhaleInteractionMark?, unattended: Bool) {
        guard let sample else {
            if isShowing && !unattended { panel.orderOut(nil) }
            view.mark = nil
            return
        }
        view.mark = sample
        guard !unattended else { return }
        panel.setFrameOrigin(NSPoint(x: sample.point.x - panel.frame.width / 2,
                                     y: sample.point.y - panel.frame.height / 2))
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private final class WhaleInteractionEffectView: NSView {
    var mark: WhaleInteractionMark?

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        guard let mark else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let fade = min(1, 4 * (1 - mark.age))
        let gold = NSColor(srgbRed: 1, green: 0.81, blue: 0.31, alpha: fade)
        let blue = NSColor(srgbRed: 0.38, green: 0.79, blue: 1, alpha: fade)
        let pink = NSColor(srgbRed: 1, green: 0.48, blue: 0.71, alpha: fade)
        context.setShadow(offset: .zero, blur: 4, color: NSColor(hue: 0.68, saturation: 0.56, brightness: 0.26, alpha: 0.75).cgColor)
        context.setLineWidth(2.2)
        switch mark.kind {
        case .burst:
            context.setStrokeColor(gold.cgColor)
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                let inner = 4 + 13 * mark.age
                let outer = inner + 8 - 4 * mark.age
                context.move(to: CGPoint(x: cos(angle) * inner, y: sin(angle) * inner))
                context.addLine(to: CGPoint(x: cos(angle) * outer, y: sin(angle) * outer))
            }
            context.strokePath()
        case .heart:
            context.setFillColor(pink.cgColor)
            context.scaleBy(x: 0.75 + mark.age * 0.35, y: 0.75 + mark.age * 0.35)
            context.move(to: CGPoint(x: 0, y: -12))
            context.addCurve(to: CGPoint(x: 0, y: 7), control1: CGPoint(x: -27, y: 5), control2: CGPoint(x: -9, y: 19))
            context.addCurve(to: CGPoint(x: 0, y: -12), control1: CGPoint(x: 9, y: 19), control2: CGPoint(x: 27, y: 5))
            context.fillPath()
        case .note:
            context.setStrokeColor(blue.cgColor)
            context.setFillColor(blue.cgColor)
            context.fillEllipse(in: CGRect(x: -9, y: -8, width: 9, height: 6))
            context.fillEllipse(in: CGRect(x: 3, y: -5, width: 9, height: 6))
            context.move(to: CGPoint(x: -1, y: -5))
            context.addLine(to: CGPoint(x: -1, y: 8))
            context.addLine(to: CGPoint(x: 11, y: 11))
            context.addLine(to: CGPoint(x: 11, y: -2))
            context.strokePath()
        case .wave:
            context.setStrokeColor(gold.cgColor)
            for index in 0..<3 {
                let radius = 7 + CGFloat(index) * 5 + mark.age * 4
                let center = mark.side > 0 ? 0.17 : CGFloat.pi - 0.17
                context.addArc(center: .zero, radius: radius, startAngle: center - 0.57,
                               endAngle: center + 0.57, clockwise: false)
                context.strokePath()
            }
        case .star:
            context.rotate(by: mark.side * mark.age * .pi * 2)
            context.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.41, alpha: 1).cgColor)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.35)
            for index in 0..<10 {
                let angle = .pi / 2 + CGFloat(index) * .pi / 5
                let radius: CGFloat = index.isMultiple(of: 2) ? 12 : 5.4
                let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                if index == 0 { context.move(to: point) }
                else { context.addLine(to: point) }
            }
            context.closePath()
            context.drawPath(using: .fillStroke)
        case .dash:
            context.setStrokeColor(blue.cgColor)
            for index in 0..<3 {
                let y = CGFloat(index - 1) * 6
                let x = -mark.side * (7 + mark.age * 12)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + mark.side * CGFloat(9 + index * 3), y: y))
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

private final class PetView: NSView {
    private let sprite = CALayer()
    private var alpha: AlphaMask?
    var onPress: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onRelease: (() -> Void)?
    var contextMenu: (() -> NSMenu)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = .linear
        sprite.minificationFilter = .linear
        layer?.addSublayer(sprite)

    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        CATransaction.commit()
    }

    func setFrame(_ frame: AnimationFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = frame.image
        CATransaction.commit()
        alpha = frame.alpha
    }

    func setDialogueSpeaking(_ speaking: Bool) {
        let key = "dialogueSpeaking"
        guard speaking else { sprite.removeAnimation(forKey: key); return }
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, 2.5, 0, 1.5, 0]
        lift.duration = 0.68
        lift.calculationMode = .cubic
        lift.repeatCount = .infinity
        sprite.add(lift, forKey: key)
    }

    func containsImage(at screenPoint: NSPoint) -> Bool {
        guard let window, window.frame.contains(screenPoint), let alpha else { return false }
        let location = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return alpha.contains(x: location.x / bounds.width, y: location.y / bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        guard containsImage(at: point) else { return }
        onPress?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        onDrag?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window, containsImage(at: window.convertPoint(toScreen: event.locationInWindow)),
              let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class PetStage {
    private struct Travel {
        let origin: NSPoint
        let destination: NSPoint
        let duration: TimeInterval
        let pose: Pose
        var startedAt: TimeInterval?
    }

    private let library: AnimationLibrary
    private let view: PetView
    private let panel: PetPanel
    private let expressions: ExpressionPanel
    private let bubble = SpeechBubble()
    private var hoverStarted: TimeInterval?
    private var hideAfter: TimeInterval = 0
    private var lastBodyPoint = NSPoint.zero
    private var previousPointer = NSPoint.zero
    private var needsHoverExit = false
    private let speech: WhaleSpeech
    private let unattendedTest: Bool
    private var animationTimer: Timer?
    private var traveling: Travel?
    private var pressedAt: NSPoint?
    private var pressOrigin = NSPoint.zero
    private var dragging = false
    private var clip: Clip?
    private var displayedSkin: Skin?
    private var displayStartedAt: TimeInterval = 0
    private var displayFrameIndex = -1
    private var requestedPose: Pose?
    private var selectedAction: Pose?
    private var revision = 0
    private var renderedRevision = 0
    private var nextSwim: TimeInterval = 0
    private var completionPending = false
    private var working = false
    private var wantsVisible = false
    private var interaction: WhaleInteractionScene?
    private var interactionStep: WhaleInteractionScene.Step?
    private let interactionEffect = WhaleInteractionEffect()
    private var interactionVoiceEvent: String?
    private var interactionDialogue: WhaleInteractionDialogue?
    private var dialoguePermit: WhaleDialoguePermit?
    private var nextDialoguePermitCheck: TimeInterval = 0
    private var dialoguePermitCommitted = false
    private var nextInteractionReport: TimeInterval = 0

    private(set) var skin: Skin
    private(set) var pose: Pose?
    private(set) var width: Int
    private(set) var homeCenter: NSPoint?
    private(set) var completedActions = 0
    private(set) var completedSwims = 0
    private(set) var interactionCompleted = 0
    private(set) var interactionCancelled = 0
    private(set) var lastInteraction: [String: Any]?
    private(set) var lastDialogue: [String: Any]?
    var dialogueStatus: [String: Any]? { interactionDialogue?.report(phase: "active") }
    var interactionEffectName: String? { interactionEffect.name }
    var interactionReady: Bool {
        wantsVisible && panel.isVisible && !working && pressedAt == nil && selectedAction == nil &&
            traveling == nil && hoverStarted == nil && !expressions.window.isVisible &&
            speech.line == nil && interaction == nil && pose == .idle
    }
    var interactionStatus: [String: Any]? {
        guard let interaction else { return nil }
        return interactionReport(interaction, phase: interactionStep?.phase.rawValue ?? "waiting", time: now)
    }
    var caption: String? { speech.line?.text }
    var speechStatus: [String: Any] { speech.status }
    private(set) var playbackError: String?
    var muted = false { didSet { speech.muted = muted } }
    var roaming = true {
        didSet {
            guard roaming != oldValue else { return }
            if roaming { arrangeSwim() }
            else if traveling != nil { traveling = nil; updatePose() }
        }
    }
    var onChange: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var contextMenu: (() -> NSMenu)?
    var allowHoverAtPoint: ((NSPoint) -> Bool)?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var windowNumber: Int { panel.windowNumber }
    var captionWindowNumber: Int { bubble.window.windowNumber }
    var captionFrame: NSRect { bubble.window.frame }
    var expressionStatus: [String: Any] { expressions.status }
    var shownSkin: Skin? { displayedSkin }
    var isTransparentToMouse: Bool { panel.ignoresMouseEvents }
    var currentFrameIndex: Int { displayFrameIndex }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(library: AnimationLibrary, resources: URL, skin: Skin, width: Int, center: NSPoint?, unattendedTest: Bool) {
        self.library = library
        speech = WhaleSpeech(resources: resources, quietTest: unattendedTest)
        expressions = ExpressionPanel(resources: resources)
        self.unattendedTest = unattendedTest
        self.skin = skin
        self.width = width
        homeCenter = center
        let bounds = NSRect(x: 0, y: 0, width: width, height: width)
        view = PetView(frame: bounds)
        panel = PetPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = view
        panel.title = "DeepSeek 大肥鱼"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        if unattendedTest { panel.alphaValue = 0 }
        panel.isReleasedWhenClosed = false

        speech.onChange = { [weak self] in self?.speechChanged() }
        expressions.onSelect = { [weak self] action in self?.play(action) }
        expressions.onChange = { [weak self] in self?.onChange?() }
        view.onPress = { [weak self] point in self?.press(at: point) }
        view.onDrag = { [weak self] point in self?.drag(to: point) }
        view.onRelease = { [weak self] in self?.release() }
        view.contextMenu = { [weak self] in
            self?.dismissExpressions()
            return self?.contextMenu?() ?? NSMenu()
        }
        placeInitial()
    }

    private var defaultCenter: NSPoint {
        let usable = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        return NSPoint(x: usable.minX + max(CGFloat(width) * 0.5 + 18, 105),
                       y: usable.minY + CGFloat(width) * 0.5 + 22)
    }

    private func placeInitial() {
        let candidate = homeCenter ?? defaultCenter
        let center = screen(containing: candidate) == nil ? defaultCenter : candidate
        let origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        panel.setFrameOrigin(constrain(origin, screen: screen(containing: center)))
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func constrain(_ origin: NSPoint, screen: NSScreen?) -> NSPoint {
        guard let usable = (screen ?? NSScreen.main)?.visibleFrame else { return origin }
        return NSPoint(x: min(max(origin.x, usable.minX), max(usable.minX, usable.maxX - frame.width)),
                       y: min(max(origin.y, usable.minY), max(usable.minY, usable.maxY - frame.height)))
    }

    func repairPosition() {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let display = screen(containing: center) {
            let point = constrain(frame.origin, screen: display)
            if point != frame.origin { panel.setFrameOrigin(point) }
        } else {
            placeInitial()
        }
    }

    func displaysChanged() {
        finishInteraction(cancelledFor: "display")
        dismissExpressions()
        traveling = nil
        arrangeSwim()
        repairPosition()
        showCaptionIfNeeded()
        updatePose()
    }

    func setWidth(_ value: Int) {
        guard width != value else { return }
        finishInteraction(cancelledFor: "size")
        dismissExpressions()
        width = value
        traveling = nil
        let rect = NSRect(x: frame.midX - Double(value) / 2, y: frame.midY - Double(value) / 2,
                          width: Double(value), height: Double(value))
        panel.setFrame(rect, display: true)
        repairPosition()
        showCaptionIfNeeded()
        updatePose()
    }

    func setSkin(_ value: Skin) {
        guard value != skin else { return }
        finishInteraction(cancelledFor: "skin")
        dismissExpressions()
        skin = value
        selectedAction = nil
        traveling = nil
        interruptSpeech()
        requestedPose = nil
        arrangeSwim()
        updatePose()
    }

    func setVisible(_ visible: Bool) {
        guard visible != wantsVisible else { return }
        wantsVisible = visible
        if visible {
            repairPosition()
            arrangeSwim()
            updatePose()
            revealIfReady()
            runTimer()
        } else {
            finishInteraction(cancelledFor: "hidden")
            dismissExpressions()
            panel.orderOut(nil)
            panel.ignoresMouseEvents = true
            animationTimer?.invalidate()
            animationTimer = nil
            traveling = nil
            pressedAt = nil
            dragging = false
            selectedAction = nil
            requestedPose = nil
            revision += 1
            interruptSpeech()
            onChange?()
        }
    }

    private func revealIfReady() {
        guard wantsVisible, clip != nil, renderedRevision == revision, !panel.isVisible else { return }
        panel.orderFrontRegardless()
        updateMouseTransparency()
    }

    private func runTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.003
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func setWorking(_ value: Bool) {
        guard working != value else { return }
        working = value
        if working {
            traveling = nil
            completionPending = false
            finishInteraction(cancelledFor: "working")
        } else { arrangeSwim() }
        updatePose()
    }

    func beginInteraction(_ request: WhaleInteraction) -> Bool {
        if interaction?.request == request { return true }
        guard interactionReady, lastInteraction?["id"] as? String != request.id.uuidString else { return false }
        let peer = request.peer.frame
        let current = NSPoint(x: frame.midX, y: frame.midY)
        let target = request.destination.location
        guard let screen = screen(containing: current), screen.frame.contains(target),
              screen.frame.contains(NSPoint(x: peer.midX, y: peer.midY)) else { return false }
        let stationary = request.behavior == .starpass ||
            (request.behavior == .beckon && request.role == .initiator)
        let destination = stationary ? frame.origin :
            constrain(NSPoint(x: target.x - frame.width / 2, y: target.y - frame.height / 2), screen: screen)
        if let dialogue = request.dialogue {
            let permit = dialogue.permitRequired == true ? WhaleDialoguePermit(interactionID: request.id) : nil
            guard dialogue.permitRequired != true || permit != nil else { return false }
            let initiator: WhaleDialogueRequest.Speaker = request.role == .initiator ? .whale : .dragon
            guard let recordings = speech.prepareDialogue(dialogue, behavior: request.behavior.rawValue,
                                                           initiator: initiator) else { return false }
            interactionDialogue = WhaleInteractionDialogue(id: request.id, script: dialogue.script, recordings: recordings)
            dialoguePermit = permit
            nextDialoguePermitCheck = 0
            dialoguePermitCommitted = false
        }
        let scene = WhaleInteractionScene(request: request, origin: frame.origin, destination: destination,
                                          display: screen.visibleFrame)
        interaction = scene
        interactionStep = scene.step(at: -1, width: frame.width)
        interactionVoiceEvent = nil
        nextInteractionReport = 0

        // Read each needed clip before the shared start so decoding cannot hold up the scene.
        var warming: Set<Pose> = [.idle]
        for progress in [0.2, 0.48, 0.73, 0.81] {
            let pose = scene.step(at: progress, width: frame.width).pose
            if warming.insert(pose).inserted { library.load(pose, skin: skin) { _ in } }
        }
        return true
    }

    func cancelInteraction(matching id: UUID?) -> Bool {
        guard let interaction else {
            return id == nil || lastInteraction?["id"] as? String == id?.uuidString
        }
        guard id == nil || id == interaction.request.id else { return false }
        finishInteraction(cancelledFor: "manager")
        return true
    }

    private func interactionReport(_ scene: WhaleInteractionScene, phase: String, time: TimeInterval) -> [String: Any] {
        let request = scene.request
        var report: [String: Any] = [
            "id": request.id.uuidString, "behavior": request.behavior.rawValue, "role": request.role.rawValue,
            "phase": phase, "progress": min(1, max(0, scene.progress(at: time))),
            "startAt": request.startAt, "duration": request.duration, "motionDuration": request.movementDuration,
            "destination": ["x": request.destination.x, "y": request.destination.y],
            "peer": screenRectValues(request.peer.frame),
            "effectVisible": interactionEffect.isShowing,
            "voiceEvent": interactionVoiceEvent as Any? ?? NSNull(),
        ]
        if let point = interactionEffect.position { report["effectPosition"] = ["x": point.x, "y": point.y] }
        return report
    }

    private func animateInteraction(at time: TimeInterval) {
        guard let scene = interaction else { return }
        let progress = scene.progress(at: time)
        guard time < scene.request.startAt + scene.request.duration else {
            finishInteraction()
            return
        }
        guard checkDialoguePermit(scene.request, at: time) else {
            finishInteraction(cancelledFor: "dialogue-permit")
            return
        }
        guard progress >= 0 else { return }
        let step = scene.step(at: progress, width: frame.width)
        let phaseChanged = step.phase != interactionStep?.phase
        let poseChanged = step.pose != interactionStep?.pose
        interactionStep = step
        let visible = scene.display
        let point = NSPoint(x: min(max(step.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width)),
                            y: min(max(step.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height)))
        if frame.origin != point { panel.setFrameOrigin(point) }
        interactionEffect.render(scene.effect(at: progress, frame: frame), unattended: unattendedTest)
        if poseChanged {
            updatePose()
            guard interaction != nil else { return }
        }
        if scene.request.dialogue != nil {
            if let reason = advanceDialogue(scene.request, at: time) {
                finishInteraction(cancelledFor: reason)
                return
            }
        } else if interactionVoiceEvent == nil, let cue = scene.voiceCue, progress >= cue.progress && progress < 0.84 {
            interactionVoiceEvent = cue.event
            speech.speak(cue.event)
        }
        if phaseChanged || time >= nextInteractionReport {
            nextInteractionReport = time + 0.12
            showCaptionIfNeeded()
            onChange?()
        }
    }

    private func checkDialoguePermit(_ request: WhaleInteraction, at time: TimeInterval, force: Bool = false) -> Bool {
        guard request.dialogue?.permitRequired == true else { return true }
        let needsCommit = dialoguePermitCommitted || time >= request.startAt || force
        if !force, time < nextDialoguePermitCheck, dialoguePermitCommitted || !needsCommit { return true }
        nextDialoguePermitCheck = time + 0.08
        guard let phase = dialoguePermit?.phase(for: request) else { return false }
        dialoguePermitCommitted = phase == .committed
        return !needsCommit || dialoguePermitCommitted
    }

    private func advanceDialogue(_ request: WhaleInteraction, at time: TimeInterval) -> String? {
        guard var dialogue = interactionDialogue, let schedule = request.dialogue else { return nil }
        if let current = dialogue.current {
            let nextIndex = current.turn.index + 1
            let nextOffset = schedule.turns.indices.contains(nextIndex) ? schedule.turns[nextIndex].offset : request.duration
            let cutoff = request.startAt + nextOffset - 0.04
            let player = current.recording.player
            let nominalEnd = current.startedAt + player.duration
            if !speech.dialogueWasMuted, !player.isPlaying, time > current.startedAt + 0.12, time < nominalEnd - 0.12 {
                return "dialogue-audio"
            }
            if time >= cutoff, player.isPlaying { return "dialogue-timing" }
            guard time >= nominalEnd, !player.isPlaying else { return nil }
            let outcome: WhaleInteractionDialogue.Playback.Outcome = speech.dialogueWasMuted ? .muted : .completed
            speech.stopDialogue()
            dialogue.endTurn(at: now, outcome: outcome)
            interactionDialogue = dialogue
            view.setDialogueSpeaking(false)
            speechChanged()
        }
        guard let recording = dialogue.next else { return nil }
        let due = request.startAt + recording.turn.offset
        guard time >= due else { return nil }
        guard checkDialoguePermit(request, at: now, force: true) else { return "dialogue-permit" }
        guard now - due <= 0.14 else { return "dialogue-timing" }
        guard speech.speakDialogue(recording) else { return "dialogue-audio" }
        let startedAt = now
        dialogue.played.append(.init(recording: recording, startedAt: startedAt))
        interactionDialogue = dialogue
        guard startedAt - due <= 0.14 else { return "dialogue-timing" }
        view.setDialogueSpeaking(true)
        speechChanged()
        return nil
    }

    private func finishInteraction(cancelledFor cancellation: String? = nil) {
        guard let scene = interaction else { return }
        let reason = cancellation ?? (interactionDialogue?.allTurnsFinished == false ? "dialogue-timing" : nil)
        let usedVoice = interactionVoiceEvent != nil
        interactionEffect.render(nil, unattended: unattendedTest)
        lastInteraction = interactionReport(scene, phase: reason == nil ? "completed" : "cancelled", time: now)
        if let reason {
            interactionCancelled += 1
            lastInteraction?["reason"] = reason
        } else {
            interactionCompleted += 1
        }
        interaction = nil
        interactionStep = nil
        interactionVoiceEvent = nil
        dialoguePermit = nil
        if var dialogue = interactionDialogue {
            speech.stopDialogue()
            let failed = reason == "dialogue-audio" || reason == "dialogue-timing"
            let outcome: WhaleInteractionDialogue.Playback.Outcome = failed ? .failed : .cancelled
            dialogue.endTurn(at: now, outcome: outcome)
            lastDialogue = dialogue.report(phase: reason == nil ? "completed" : "cancelled")
            lastDialogue?["reason"] = reason
            interactionDialogue = nil
            view.setDialogueSpeaking(false)
            bubble.window.orderOut(nil)
        }
        if reason != nil && usedVoice { speech.interrupt() }
        arrangeSwim()
        updatePose()
        speakPendingCompletionIfReady()
        onChange?()
    }

    @discardableResult
    func play(_ action: Pose) -> Bool {
        guard wantsVisible, Pose.actions.contains(action), library.supports(action, skin: skin) else { return false }
        finishInteraction(cancelledFor: "expression")
        traveling = nil
        dismissExpressions()
        selectedAction = action
        interruptSpeech()
        requestedPose = nil
        updatePose()
        return true
    }

    func notifyFinished() {
        guard wantsVisible, pressedAt == nil else { return }
        completionPending = true
        speakPendingCompletionIfReady()
    }

    func cancelPendingCompletion() {
        completionPending = false
    }

    private func speakPendingCompletionIfReady() {
        guard completionPending, !working, selectedAction == nil, speech.line == nil, interaction == nil else { return }
        completionPending = false
        speech.speak("task_done")
    }

    private func interruptSpeech() {
        completionPending = false
        speech.interrupt()
    }

    private func speechChanged() {
        if caption == nil {
            bubble.window.orderOut(nil)
            speakPendingCompletionIfReady()
        } else {
            showCaptionIfNeeded()
        }
        onChange?()
    }

    private func showCaptionIfNeeded() {
        guard let caption, wantsVisible, !unattendedTest else { return }
        bubble.show(caption, near: frame, on: panel.screen)
    }

    private func updatePose() {
        guard wantsVisible else { return }
        let base: Pose = working ? .work : .idle
        let dragPose: Pose = library.supports(.drag, skin: skin) ? .drag : .idle
        let interactionPose = interactionStep?.pose
        let next = dragging ? dragPose : selectedAction ?? interactionPose ?? traveling?.pose ?? base
        guard next != requestedPose else { return }
        requestedPose = next
        revision += 1
        let ticket = revision
        let currentSkin = skin
        library.load(next, skin: currentSkin) { [weak self] clip in
            guard let self, self.revision == ticket, self.wantsVisible else { return }
            guard let clip else {
                self.playbackError = "\(currentSkin.rawValue)/\(next.rawValue)"
                self.selectedAction = nil
                self.traveling = nil
                if self.interaction != nil {
                    self.finishInteraction(cancelledFor: "animation")
                    return
                }
                self.onChange?()
                if next != .idle {
                    self.requestedPose = nil
                    self.loadIdleFallback()
                }
                return
            }
            self.playbackError = nil
            self.present(clip, as: next, skin: currentSkin)
        }
    }

    private func loadIdleFallback() {
        let ticket = revision
        let skin = skin
        requestedPose = .idle
        library.load(.idle, skin: skin) { [weak self] clip in
            guard let self, let clip, self.revision == ticket, self.wantsVisible else { return }
            self.present(clip, as: .idle, skin: skin)
        }
    }

    private func present(_ clip: Clip, as next: Pose, skin: Skin) {
        self.clip = clip
        renderedRevision = revision
        pose = next
        displayedSkin = skin
        displayStartedAt = now
        displayFrameIndex = 0
        view.setFrame(clip.frames[0])
        if traveling?.pose == next { traveling?.startedAt = displayStartedAt }
        revealIfReady()
        if selectedAction == next { speech.speak(next.rawValue) }
        onChange?()
    }

    private func arrangeSwim() {
        nextSwim = now + .random(in: 12...25)
    }

    private func beginSwim() {
        arrangeSwim()
        let currentCenter = NSPoint(x: frame.midX, y: frame.midY)
        let display = screen(containing: currentCenter)
        let anchor = homeCenter.flatMap { point in
            screen(containing: point) == display ? point : nil
        } ?? defaultCenter
        let bed = NSPoint(x: anchor.x - frame.width / 2, y: anchor.y - frame.height / 2)
        let steps: [CGFloat] = [-115, -62, 64, 122, 176]
        let candidates = steps.map {
            constrain(NSPoint(x: bed.x + $0, y: bed.y), screen: display)
        }.filter { abs($0.x - frame.minX) >= 38 }
        guard let destination = candidates.randomElement() else { return }
        let distance = abs(destination.x - frame.minX)
        traveling = Travel(origin: frame.origin, destination: destination,
                           duration: max(1.1, distance / 100),
                           pose: destination.x < frame.minX ? .walkLeft : .walkRight)
        updatePose()
    }

    private func tick() {
        let time = now
        animateInteraction(at: time)
        if let traveling, let start = traveling.startedAt {
            let progress = min(1, (time - start) / traveling.duration)
            let blend = progress * progress * (3 - 2 * progress)
            let start = traveling.origin
            let end = traveling.destination
            panel.setFrameOrigin(NSPoint(x: start.x + (end.x - start.x) * blend,
                                         y: start.y + (end.y - start.y) * blend))
            if progress == 1 {
                self.traveling = nil
                completedSwims += 1
                arrangeSwim()
                updatePose()
            }
        }
        if let clip, let pose {
            let isAction = Pose.actions.contains(pose)
            let synchronizedStart: TimeInterval?
            if let interaction, let step = interactionStep, step.pose == pose, pose != .idle {
                synchronizedStart = interaction.request.startAt + step.poseStart * interaction.request.movementDuration
            } else {
                synchronizedStart = nil
            }
            let start = synchronizedStart ?? displayStartedAt
            let elapsed = time - start
            let index = clip.index(at: elapsed, loop: !isAction || synchronizedStart != nil)
            if index != displayFrameIndex {
                displayFrameIndex = index
                view.setFrame(clip.frames[index])
            }
            if isAction, pose == selectedAction, renderedRevision == revision, elapsed >= clip.duration {
                completedActions += 1
                selectedAction = nil
                arrangeSwim()
                updatePose()
                speakPendingCompletionIfReady()
            }
        }
        if roaming, !working, pressedAt == nil, !expressions.window.isVisible, hoverStarted == nil,
           selectedAction == nil, traveling == nil, interaction == nil,
           pose == .idle, time >= nextSwim {
            beginSwim()
        }
        updateMouseTransparency()
    }

    private func updateMouseTransparency() {
        guard !unattendedTest else { return }
        let point = NSEvent.mouseLocation
        let onBody = view.containsImage(at: point) && (allowHoverAtPoint?(point) ?? true)
        let accepts = pressedAt != nil || onBody
        updateExpressions(at: point, onBody: onBody)
        if panel.ignoresMouseEvents == accepts {
            panel.ignoresMouseEvents = !accepts
        }
    }

    private func dismissExpressions() {
        hoverStarted = nil
        needsHoverExit = true
        expressions.hide()
    }

    // Only the opaque sprite and the panel receive clicks. This triangle keeps the panel
    // open while the pointer crosses the transparent margin between those two surfaces.
    private func movingBetweenPetAndPanel(_ point: NSPoint) -> Bool {
        let rect = expressions.window.frame
        let edgeX = rect.midX > frame.midX ? rect.minX : rect.maxX
        let distance = edgeX - lastBodyPoint.x
        guard abs(distance) > 1 else { return false }
        let t = (point.x - lastBodyPoint.x) / distance
        guard (0...1).contains(t) else { return false }
        let low = lastBodyPoint.y + (rect.minY - lastBodyPoint.y) * t - 7
        let high = lastBodyPoint.y + (rect.maxY - lastBodyPoint.y) * t + 7
        return (low...high).contains(point.y) && point != previousPointer
    }

    private func updateExpressions(at point: NSPoint, onBody: Bool) {
        defer { previousPointer = point }
        guard wantsVisible, panel.isVisible, pressedAt == nil else { return }
        let time = now
        if expressions.window.isVisible {
            if onBody { lastBodyPoint = point }
            if onBody || expressions.window.frame.contains(point) || movingBetweenPetAndPanel(point) {
                hideAfter = time + 0.40
            } else if time >= hideAfter {
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
        if traveling != nil { traveling = nil; arrangeSwim(); updatePose() }
        let start = hoverStarted ?? time
        hoverStarted = start
        guard time - start >= 0.16 else { return }
        hoverStarted = nil
        lastBodyPoint = point
        hideAfter = time + 0.40
        let choices = Pose.expressions.filter { library.supports($0, skin: skin) }
        expressions.show(choices: choices, near: frame, on: panel.screen)
    }

    private func press(at point: NSPoint) {
        dismissExpressions()
        pressedAt = point
        pressOrigin = frame.origin
        finishInteraction(cancelledFor: "pointer")
        if traveling != nil { traveling = nil; updatePose() }
        onChange?()
    }

    private func drag(to point: NSPoint) {
        guard let pressedAt else { return }
        let dx = point.x - pressedAt.x
        let dy = point.y - pressedAt.y
        if !dragging {
            guard hypot(dx, dy) >= 4 else { return }
            dragging = true
            selectedAction = nil
            interruptSpeech()
            updatePose()
        }
        let target = NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy)
        panel.setFrameOrigin(constrain(target, screen: screen(containing: point)))
    }

    private func release() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        if dragging {
            dragging = false
            let center = NSPoint(x: frame.midX, y: frame.midY)
            homeCenter = center
            onMoved?(center)
            arrangeSwim()
            updatePose()
        } else {
            play(.greeting)
        }
        updateMouseTransparency()
        onChange?()
    }
}
