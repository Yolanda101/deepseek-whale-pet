import AppKit

private final class SparkView: NSView {
    var phase: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: sin(phase * .pi * 2) * 0.24)
        let fill = NSColor(srgbRed: 1, green: 0.92, blue: 0.69, alpha: 1)
        let rim = NSColor(srgbRed: 0.46, green: 0.25, blue: 0.53, alpha: 1)
        context.setShadow(offset: .zero, blur: 5, color: fill.cgColor)
        let star = NSBezierPath()
        let radius: CGFloat = 7.8 + 1.8 * abs(cos(phase * .pi * 2))
        for index in 0..<10 {
            let angle = .pi / 2 + CGFloat(index) * .pi / 5
            let r = index.isMultiple(of: 2) ? radius : radius * 0.48
            let point = NSPoint(x: cos(angle) * r, y: sin(angle) * r)
            if index == 0 { star.move(to: point) } else { star.line(to: point) }
        }
        star.close()
        fill.setFill()
        star.fill()
        rim.setStroke()
        star.lineWidth = 1.25
        star.stroke()
        context.restoreGState()
    }
}

final class StarPass {
    static let duration: TimeInterval = 2.5
    private let marker = SparkView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: marker.frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = marker
        panel.isReleasedWhenClosed = false
        return panel
    }()
    private var timer: Timer?
    private(set) var passesStarted = 0
    private(set) var passesCompleted = 0

    static func point(from a: CGPoint, to b: CGPoint, progress: CGFloat, visible: CGRect) -> CGPoint {
        let progress = min(1, max(0, progress))
        let outward = progress < 0.5
        let t = outward ? progress * 2 : (progress - 0.5) * 2
        let start = outward ? a : b, end = outward ? b : a
        let arc = min(70, max(23, hypot(end.x - start.x, end.y - start.y) * 0.27))
        let room = max(0, visible.maxY - 12 - max(start.y, end.y))
        return CGPoint(x: start.x + (end.x - start.x) * t,
                       y: start.y + (end.y - start.y) * t + min(arc, room) * sin(t * .pi))
    }

    func play(companion: CGRect, native: CGRect) {
        cancel()
        let a = CGPoint(x: companion.midX, y: companion.minY + companion.height * 0.62)
        let b = CGPoint(x: native.midX, y: native.minY + native.height * 0.62)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(a) && $0.frame.contains(b) }) else { return }
        let start = ProcessInfo.processInfo.systemUptime
        passesStarted += 1
        move(to: a, phase: 0)
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = (ProcessInfo.processInfo.systemUptime - start) / Self.duration
            guard t < 1 else {
                self.passesCompleted += 1
                self.cancel()
                return
            }
            self.move(to: Self.point(from: a, to: b, progress: t, visible: screen.visibleFrame), phase: t)
        }
        timer.tolerance = 0.004
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func move(to point: NSPoint, phase: CGFloat) {
        marker.phase = phase
        marker.needsDisplay = true
        panel.setFrameOrigin(NSPoint(x: point.x - marker.bounds.midX, y: point.y - marker.bounds.midY))
    }

    func cancel() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }
}
