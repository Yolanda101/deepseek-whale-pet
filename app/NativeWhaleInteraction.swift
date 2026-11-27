import AppKit
import ImageIO
import QuartzCore

private struct NativeFrameLayout: Decodable {
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let imageWidth: CGFloat
    let imageHeight: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init?(resources: URL) {
        let file = resources.appendingPathComponent("NativeFrames.json")
        guard let data = try? Data(contentsOf: file),
              let layout = try? JSONDecoder().decode(Self.self, from: data),
              layout.tileWidth == 192, layout.tileHeight == 208,
              layout.imageWidth > 0, layout.imageHeight > 0 else { return nil }
        self = layout
    }

    func spriteRect(in cell: NSRect) -> NSRect {
        let sx = cell.width / tileWidth
        let sy = cell.height / tileHeight
        return NSRect(x: cell.minX + offsetX * sx, y: cell.maxY - (offsetY + imageHeight) * sy,
                      width: imageWidth * sx, height: imageHeight * sy)
    }
}

private struct NativeBodyMask {
    private let width: Int
    private let height: Int
    private let alpha: [UInt8]

    init?(resources: URL) {
        let url = resources.appendingPathComponent("NativeMask.png") as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 192, image.height == 208 else { return nil }
        width = image.width
        height = image.height
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
              let data = context.data else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let byteCount = width * height * 4
        alpha = withExtendedLifetime(context) {
            stride(from: 3, to: byteCount, by: 4).map { pixels[$0] }
        }
    }

    func contains(_ point: NSPoint, in rect: NSRect) -> Bool {
        guard rect.contains(point) else { return false }
        let x = Int((point.x - rect.minX) / rect.width * CGFloat(width))
        let y = height - 1 - Int((point.y - rect.minY) / rect.height * CGFloat(height))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return alpha[y * width + x] >= 45
    }
}

private final class NativeActionView: NSView {
    let sprite = CALayer()
    var calibration: NativeFrameLayout?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.988, green: 0.976, blue: 0.949, alpha: 1).cgColor
        layer?.masksToBounds = true
        sprite.contentsGravity = .resize
        sprite.minificationFilter = .linear
        sprite.magnificationFilter = .linear
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(10, bounds.width * 0.07)
        sprite.frame = calibration?.spriteRect(in: bounds) ?? .zero
        CATransaction.commit()
    }

    func drawFrame(_ frame: AnimationFrame?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = frame?.image
        CATransaction.commit()
    }
}

final class NativeWhaleInteraction {
    private let library: AnimationLibrary
    private let speech: WhaleSpeech
    private let locate: () -> NativePetLocation?
    private let pointer: () -> NSPoint
    private let pressedButtons: () -> Int
    private let mask: NativeBodyMask?
    private let menu: ExpressionPanel
    private let bubble = SpeechBubble()
    private let overlay = PetPanel(overlaySize: NSSize(width: 192, height: 208), title: "原生大肥鱼动作")
    private let view = NativeActionView(frame: .zero)
    private var pollTimer: Timer?
    private var frameTimer: Timer?
    private var location: NativePetLocation?
    private var nextLookup: TimeInterval = 0
    private var hoverSince: TimeInterval?
    private var hideAfter: TimeInterval = 0
    private var lastBodyPoint = NSPoint.zero
    private var previousPointer = NSPoint.zero
    private var needsExit = false
    private var revision = 0
    private var pending: Pose?
    private var playing: Pose?
    private var clip: Clip?
    private var startedAt: TimeInterval = 0
    private var frameIndex = -1
    private var frameDeadline: TimeInterval = 0
    private var frameBegan: TimeInterval = 0
    private var delayedBy: TimeInterval = 0
    private var visited: Set<Int> = []
    private var completed = 0
    private var lastPlayback: [String: Any]?
    private var error: String?
    private var overlapOrder: (native: CGWindowID, companion: Int, until: TimeInterval, companionAbove: Bool)?

    var companionHitTest: ((NSPoint) -> (windowNumber: Int, opaque: Bool)?)?
    var onChange: (() -> Void)?
    var muted = false { didSet { speech.muted = muted } }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    convenience init(library: AnimationLibrary, resources: URL, target: NativeWhaleTarget) {
        self.init(library: library, resources: resources, locate: target.current,
                  pointer: { NSEvent.mouseLocation }, pressedButtons: { NSEvent.pressedMouseButtons })
    }

    init(library: AnimationLibrary, resources: URL, locate: @escaping () -> NativePetLocation?,
         pointer: @escaping () -> NSPoint, pressedButtons: @escaping () -> Int, offscreen: Bool = false) {
        self.library = library
        speech = WhaleSpeech(resources: resources, quietTest: offscreen)
        self.locate = locate
        self.pointer = pointer
        self.pressedButtons = pressedButtons
        mask = NativeBodyMask(resources: resources)
        menu = ExpressionPanel(resources: resources)
        view.calibration = NativeFrameLayout(resources: resources)
        if view.calibration == nil || mask == nil { error = "原生宠物的定位素材不完整" }
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.contentView = view
        menu.window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        bubble.window.level = menu.window.level
        if offscreen {
            for window in [overlay, menu.window, bubble.window] {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
        }
        speech.onChange = { [weak self] in
            guard let self else { return }
            if let location = self.location, self.speech.line != nil { self.showCaption(at: location) }
            else { self.bubble.window.orderOut(nil) }
            self.onChange?()
        }
        menu.onSelect = { [weak self] in self?.select($0) }
        menu.onChange = { [weak self] in self?.onChange?() }
    }

    func start() {
        guard pollTimer == nil, mask != nil, view.calibration != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        nextLookup = 0
        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        location = nil
        cancel()
        onChange?()
    }

    var status: [String: Any] {
        var result: [String: Any] = [
            "targetVisible": location != nil, "menu": menu.status, "frameIndex": frameIndex,
            "frameCount": clip?.frames.count ?? 0, "completedActions": completed, "overlayVisible": overlay.isVisible,
            "overlayWindowNumber": overlay.windowNumber, "captionWindowNumber": bubble.window.windowNumber,
        ]
        result["targetFrame"] = location.map { screenRectValues($0.frame) } as Any? ?? NSNull()
        result["targetWindowNumber"] = location.map { Int($0.windowID) } as Any? ?? NSNull()
        result["pose"] = playing?.rawValue as Any? ?? NSNull()
        result["pendingPose"] = pending?.rawValue as Any? ?? NSNull()
        result["actionFrame"] = overlay.isVisible ? screenRectValues(overlay.frame) as Any : NSNull()
        result["spriteFrame"] = overlay.isVisible ? view.calibration.map {
            screenRectValues($0.spriteRect(in: overlay.frame))
        } as Any? ?? NSNull() : NSNull()
        result["caption"] = speech.line?.text as Any? ?? NSNull()
        result["voice"] = speech.status
        result["lastPlayback"] = lastPlayback as Any? ?? NSNull()
        result["playbackError"] = error as Any? ?? NSNull()
        return result
    }

    private func companionIsAbove(at point: NSPoint, native: NativePetLocation) -> Bool {
        guard let companion = companionHitTest?(point), companion.opaque else { return false }
        let time = now
        if let cached = overlapOrder, cached.native == native.windowID, cached.companion == companion.windowNumber,
           time < cached.until { return cached.companionAbove }
        // The native window includes wide transparent margins. Only compare the order of the
        // two real pet windows here, after both silhouettes matched the same point.
        let aboveWindows = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, native.windowID) as? [[String: Any]]
        let above = aboveWindows?.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == companion.windowNumber
        } ?? true
        overlapOrder = (native.windowID, companion.windowNumber, time + 0.10, above)
        return above
    }

    private func screen(for location: NativePetLocation) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == location.displayID
        }
    }

    private func poll() {
        let time = now
        if time >= nextLookup {
            follow(locate())
            nextLookup = time + (location == nil ? 0.42 : 0.10)
        }
        guard let location else { return }
        let point = pointer()
        let body = mask?.contains(point, in: location.frame) == true && !companionIsAbove(at: point, native: location)
        defer { previousPointer = point }
        if pressedButtons() != 0 {
            if menu.window.isVisible && menu.window.frame.contains(point) { return }
            // The caller can always start a native drag, including during an expression.
            if body || menu.window.isVisible { cancel(); needsExit = true }
            hoverSince = nil
            return
        }
        if pending != nil { return }
        if menu.window.isVisible {
            if body { lastBodyPoint = point }
            let panel = menu.window.frame
            if body || panel.contains(point) || inTransit(point, panel: panel) {
                hideAfter = time + 0.40
            } else if time >= hideAfter {
                menu.hide()
            }
            return
        }
        guard body else { hoverSince = nil; needsExit = false; return }
        guard !needsExit else { return }
        let start = hoverSince ?? time
        hoverSince = start
        guard time - start >= 0.16 else { return }
        lastBodyPoint = point
        hideAfter = time + 0.40
        hoverSince = nil
        showMenu(at: location)
    }

    private func inTransit(_ point: NSPoint, panel: NSRect) -> Bool {
        guard point != previousPointer else { return false }
        let edge = panel.midX > lastBodyPoint.x ? panel.minX : panel.maxX
        let distance = edge - lastBodyPoint.x
        guard abs(distance) > 1 else { return false }
        let t = (point.x - lastBodyPoint.x) / distance
        guard (0...1).contains(t) else { return false }
        let low = lastBodyPoint.y + (panel.minY - lastBodyPoint.y) * t - 7
        let high = lastBodyPoint.y + (panel.maxY - lastBodyPoint.y) * t + 7
        return (low...high).contains(point.y)
    }

    private func follow(_ found: NativePetLocation?) {
        guard location != found else { return }
        let old = location
        location = found
        overlapOrder = nil
        if old?.windowID != found?.windowID || old?.displayID != found?.displayID {
            cancel()
            needsExit = false
        }
        if let found {
            if menu.window.isVisible { showMenu(at: found) }
            if playing != nil { positionOverlay(at: found) }
            if speech.line != nil { showCaption(at: found) }
        }
        onChange?()
    }

    private func showMenu(at location: NativePetLocation) {
        let choices = Pose.expressions.filter { library.supports($0, skin: .figurine) }
        menu.show(choices: choices, near: location.frame, on: screen(for: location))
    }

    private func positionOverlay(at location: NativePetLocation) {
        if overlay.frame != location.frame { overlay.setFrame(location.frame, display: true) }
        view.layoutSubtreeIfNeeded()
    }

    private func select(_ pose: Pose) {
        guard menu.window.isVisible, let original = location else { return }
        follow(locate())
        guard let current = location, current.windowID == original.windowID, current.displayID == original.displayID,
              library.supports(pose, skin: .figurine) else { menu.hide(); return }
        cancel()
        needsExit = true
        revision += 1
        let ticket = revision
        pending = pose
        onChange?()
        library.load(pose, skin: .figurine) { [weak self] clip in
            guard let self, self.revision == ticket, self.pending == pose else { return }
            self.follow(self.locate())
            guard self.revision == ticket, let location = self.location else { return }
            guard let clip else {
                self.pending = nil
                self.error = "无法读取原生大肥鱼动作 " + pose.rawValue
                self.onChange?()
                return
            }
            self.pending = nil
            self.playing = pose
            self.clip = clip
            self.error = nil
            self.frameIndex = 0
            self.visited = [0]
            self.positionOverlay(at: location)
            self.view.drawFrame(clip.frames[0])
            self.overlay.order(.above, relativeTo: Int(location.windowID))
            self.speech.speak(pose.rawValue)
            self.startedAt = self.now
            self.frameBegan = self.startedAt
            self.delayedBy = 0
            self.frameDeadline = self.startedAt + clip.endTime(ofFrame: 0)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.animate() }
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            self.frameTimer = timer
            self.onChange?()
        }
    }

    private func animate() {
        guard let clip, let pose = playing else { return }
        let time = now
        guard time >= frameDeadline else { return }
        let next = frameIndex + 1
        if next < clip.frames.count {
            let scheduledEnd = startedAt + delayedBy + clip.endTime(ofFrame: next)
            // A delayed main run loop must never discard an entire authored pose.
            // Resume from the next drawing and give it its own time on screen.
            if time >= scheduledEnd { delayedBy += time - frameDeadline }
            frameDeadline = startedAt + delayedBy + clip.endTime(ofFrame: next)
            frameBegan = time
            frameIndex = next
            visited.insert(next)
            view.drawFrame(clip.frames[next])
            return
        }
        lastPlayback = ["pose": pose.rawValue, "frameCount": clip.frames.count, "visitedFrameCount": visited.count,
                        "lastFrameIndex": frameIndex, "durationMs": Int(((time - startedAt) * 1000).rounded()),
                        "lastFrameHeldMs": Int(((time - frameBegan) * 1000).rounded()),
                        "delayCompensationMs": Int((delayedBy * 1000).rounded()),
                        "expectedDurationMs": Int((clip.duration * 1000).rounded())]
        completed += 1
        finishAnimation()
        onChange?()
    }

    private func showCaption(at location: NativePetLocation) {
        guard let text = speech.line?.text else { return }
        bubble.show(text, near: location.frame, on: screen(for: location))
    }

    private func cancel() {
        revision += 1
        hoverSince = nil
        finishAnimation()
        menu.hide()
        speech.interrupt()
    }

    // The original Codex sprite returns immediately; a longer voice line keeps its own lifetime.
    private func finishAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        pending = nil
        playing = nil
        clip = nil
        frameIndex = -1
        visited = []
        overlay.orderOut(nil)
        view.drawFrame(nil)
    }
}
