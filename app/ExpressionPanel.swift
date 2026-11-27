import AppKit

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(overlaySize size: NSSize, title: String) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
    }
}

func screenRectValues(_ rect: NSRect) -> [String: CGFloat] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

private func fittedOrigin(_ origin: NSPoint, size: NSSize, within rect: NSRect) -> NSPoint {
    NSPoint(x: max(rect.minX, min(origin.x, rect.maxX - size.width)),
            y: max(rect.minY, min(origin.y, rect.maxY - size.height)))
}

final class SpeechBubble {
    let window = PetPanel(overlaySize: NSSize(width: 120, height: 25), title: "大肥鱼字幕")
    private let label = NSTextField(wrappingLabelWithString: "")
    private let font = NSFont.systemFont(ofSize: 12, weight: .bold)

    init() {
        window.ignoresMouseEvents = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42).cgColor
        label.textColor = .black
        label.alignment = .center
        label.font = font
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        content.addSubview(label)
        window.contentView = content
    }

    func show(_ text: String, near pet: NSRect, on screen: NSScreen?) {
        guard let screen else { return }
        let usable = screen.visibleFrame.insetBy(dx: 5, dy: 5)
        let halo = NSShadow()
        halo.shadowColor = NSColor.white.withAlphaComponent(0.34)
        halo.shadowBlurRadius = 0.7
        halo.shadowOffset = .zero
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph, .shadow: halo,
        ])
        let naturalWidth = label.cell?.cellSize.width ?? (text as NSString).size(withAttributes: [.font: font]).width
        let textWidth = min(244, max(35, ceil(naturalWidth) + 8))
        let measure = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200))
        let textHeight = max(17, ceil(measure?.height ?? 17))
        let size = NSSize(width: textWidth + 18, height: textHeight + 10)
        let above = pet.maxY + 3
        let y = above + size.height <= usable.maxY ? above : pet.minY - size.height - 3
        let point = fittedOrigin(NSPoint(x: pet.midX - size.width / 2, y: y), size: size, within: usable)
        window.setFrame(NSRect(origin: point, size: size), display: true)
        label.frame = NSRect(x: 9, y: 5, width: textWidth, height: textHeight)
        window.orderFrontRegardless()
    }
}

private final class PageArrow: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ExpressionButton: NSButton {
    let pose: Pose
    private let icon: NSImage
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(pose: Pose, icon: NSImage, frame: NSRect) {
        self.pose = pose
        self.icon = icon
        super.init(frame: frame)
        title = pose.expressionTitle
        setAccessibilityLabel(title)
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor(srgbRed: 0.91, green: 0.95, blue: 0.99, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        let imageRect = NSRect(x: (bounds.width - 41) / 2, y: isFlipped ? 2 : bounds.height - 43,
                               width: 41, height: 41)
        icon.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.15, green: 0.18, blue: 0.22, alpha: 1),
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: isFlipped ? 43 : 4), withAttributes: attributes)
    }
}

final class ExpressionPanel: NSObject {
    private static let size = NSSize(width: 162, height: 191)
    let window = PetPanel(overlaySize: size, title: "大肥鱼表情")
    private let content = NSView(frame: NSRect(origin: .zero, size: size))
    private var icons: [Pose: NSImage] = [:]
    private var choices: [Pose] = []
    private var buttons: [ExpressionButton] = []
    private let previous = PageArrow()
    private let next = PageArrow()
    private var page = 0
    private var pageCount: Int { max(1, (choices.count + 5) / 6) }
    var onSelect: ((Pose) -> Void)?
    var onChange: (() -> Void)?

    static func verifyIcons(at resources: URL) throws {
        for pose in Pose.expressions {
            let url = resources.appendingPathComponent("Expressions").appendingPathComponent(pose.rawValue + ".png")
            guard let frame = AnimationFrame(url), frame.image.width >= 41, frame.image.width == frame.image.height,
                  frame.alpha.hasTransparency else { throw AssetError("表情图标缺失或损坏 " + pose.rawValue) }
        }
    }

    init(resources: URL) {
        super.init()
        for pose in Pose.expressions {
            let url = resources.appendingPathComponent("Expressions").appendingPathComponent(pose.rawValue + ".png")
            icons[pose] = NSImage(contentsOf: url)
        }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.layer?.cornerRadius = 13
        content.layer?.borderWidth = 0.7
        content.layer?.borderColor = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.90, alpha: 1).cgColor
        window.contentView = content
        for (button, symbol, title, x) in [(previous, "chevron.left", "上一页", CGFloat(1)),
                                             (next, "chevron.right", "下一页", Self.size.width - 19)] {
            button.frame = NSRect(x: x, y: (Self.size.height - 42) / 2, width: 18, height: 42)
            button.isBordered = false
            button.focusRingType = .none
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(title)
            button.target = self
            button.action = #selector(changePage(_:))
            content.addSubview(button)
        }
    }

    func show(choices: [Pose], near pet: NSRect, on screen: NSScreen?) {
        guard let screen, !choices.isEmpty else { return }
        if !window.isVisible || self.choices != choices {
            self.choices = choices
            page = 0
            render()
        }
        let area = screen.visibleFrame.insetBy(dx: 5, dy: 5)
        let size = Self.size
        let right = pet.maxX + 3
        let left = pet.minX - size.width - 3
        let roomOnRight = area.maxX - pet.maxX
        let roomOnLeft = pet.minX - area.minX
        let placeRight = right + size.width <= area.maxX || (left < area.minX && roomOnRight >= roomOnLeft)
        let x = placeRight ? right : left
        let point = fittedOrigin(NSPoint(x: x, y: pet.midY - size.height / 2), size: size, within: area)
        if window.frame.origin != point { window.setFrameOrigin(point) }
        if !window.isVisible { window.orderFrontRegardless() }
        onChange?()
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        onChange?()
    }

    private func render() {
        for button in buttons { button.removeFromSuperview() }
        buttons = []
        let visible = choices.dropFirst(page * 6).prefix(6)
        for (slot, pose) in visible.enumerated() {
            guard let icon = icons[pose] else { continue }
            let frame = NSRect(x: 20 + (slot % 2) * 61, y: 7 + (2 - slot / 2) * 59, width: 61, height: 59)
            let button = ExpressionButton(pose: pose, icon: icon, frame: frame)
            button.target = self
            button.action = #selector(selectPose(_:))
            content.addSubview(button)
            buttons.append(button)
        }
        previous.isHidden = pageCount == 1
        next.isHidden = pageCount == 1
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < pageCount
        for arrow in [previous, next] {
            arrow.contentTintColor = arrow.isEnabled ? NSColor(calibratedWhite: 0.34, alpha: 1) : NSColor(calibratedWhite: 0.8, alpha: 1)
        }
    }

    @objc private func selectPose(_ sender: ExpressionButton) { onSelect?(sender.pose) }
    @objc private func changePage(_ sender: NSButton) {
        let target = page + (sender === next ? 1 : -1)
        guard (0..<pageCount).contains(target) else { return }
        page = target
        render()
        onChange?()
    }

    var status: [String: Any] {
        func rect(_ button: NSButton) -> [String: CGFloat] {
            screenRectValues(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        let items: [[String: Any]] = buttons.map { button in
            var item: [String: Any] = rect(button)
            item["pose"] = button.pose.rawValue
            item["title"] = button.title
            return item
        }
        return ["visible": window.isVisible, "windowNumber": window.windowNumber, "page": page + 1,
                "pageCount": pageCount, "frame": screenRectValues(window.frame), "items": items,
                "previous": previous.isEnabled && !previous.isHidden ? rect(previous) as Any : NSNull(),
                "next": next.isEnabled && !next.isHidden ? rect(next) as Any : NSNull()]
    }
}
