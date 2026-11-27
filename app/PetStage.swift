import AppKit
import QuartzCore

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

    private(set) var skin: Skin
    private(set) var pose: Pose?
    private(set) var width: Int
    private(set) var homeCenter: NSPoint?
    private(set) var completedActions = 0
    private(set) var completedSwims = 0
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
        dismissExpressions()
        traveling = nil
        arrangeSwim()
        repairPosition()
        showCaptionIfNeeded()
        updatePose()
    }

    func setWidth(_ value: Int) {
        guard width != value else { return }
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
        if working { traveling = nil; completionPending = false }
        else { arrangeSwim() }
        updatePose()
    }

    @discardableResult
    func play(_ action: Pose) -> Bool {
        guard wantsVisible, Pose.actions.contains(action), library.supports(action, skin: skin) else { return false }
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
        guard completionPending, !working, selectedAction == nil, speech.line == nil else { return }
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
        let next = dragging ? dragPose : selectedAction ?? traveling?.pose ?? base
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
            let elapsed = time - displayStartedAt
            let index = clip.index(at: elapsed, loop: !isAction)
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
           selectedAction == nil, traveling == nil,
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
        if traveling != nil { traveling = nil; updatePose() }
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
