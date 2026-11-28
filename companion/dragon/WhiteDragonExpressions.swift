import AppKit

enum WhiteDragonExpression: String, CaseIterable {
    case greeting, dance, playful, cheer, shy, sleepy, water, stretch

    var title: String {
        switch self {
        case .greeting: return "打招呼"
        case .dance: return "跳舞"
        case .playful: return "撒娇"
        case .cheer: return "加油"
        case .shy: return "害羞"
        case .sleepy: return "困困"
        case .water: return "喝水"
        case .stretch: return "伸懒腰"
        }
    }

    var animation: String {
        switch self {
        case .greeting, .stretch: return "waving"
        case .dance: return "dance"
        case .playful, .cheer: return "jumping"
        case .shy, .water: return "waiting"
        case .sleepy: return "idle"
        }
    }

    var effect: String? {
        switch self {
        case .greeting: return nil
        case .dance: return "🎵"
        case .playful: return "💕"
        case .cheer: return "🌟"
        case .shy: return "💫"
        case .sleepy: return "💤"
        case .water: return "🥛"
        case .stretch: return "✨"
        }
    }

    var iconTime: Double {
        switch self {
        case .greeting: return 0.36
        case .dance: return 0.48
        case .playful: return 0.25
        case .cheer: return 0.53
        case .shy: return 0.60
        case .sleepy: return 0.58
        case .water: return 0.48
        case .stretch: return 0.53
        }
    }

    var line: String {
        switch self {
        case .greeting: return "你好，我是白龙！"
        case .dance: return "一起来跳舞吧！"
        case .playful: return "再陪我一会儿，好不好？"
        case .cheer: return "别着急，我陪你一起完成。"
        case .shy: return "哎呀，这样看着我，我会不好意思的。"
        case .sleepy: return "有一点困了，陪我休息一小会儿吧。"
        case .water: return "喝口水吧。"
        case .stretch: return "伸个懒腰吧。"
        }
    }
}

enum WhiteDragonPanelRequest: String {
    case show, hide, next, previous
}

private final class DragonPanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class DragonExpressionButton: NSButton {
    let expression: WhiteDragonExpression
    private let icon: NSImage
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(expression: WhiteDragonExpression, icon: NSImage, frame: NSRect) {
        self.expression = expression
        self.icon = icon
        super.init(frame: frame)
        title = expression.title
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

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor(srgbRed: 0.91, green: 0.95, blue: 0.99, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        let rect = NSRect(x: (bounds.width - 41) / 2, y: isFlipped ? 2 : bounds.height - 43,
                          width: 41, height: 41)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if let effect = expression.effect {
            (effect as NSString).draw(at: NSPoint(x: rect.maxX - 11, y: rect.minY + (isFlipped ? 0 : 25)),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.15, green: 0.18, blue: 0.22, alpha: 1),
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: isFlipped ? 43 : 4),
                  withAttributes: attributes)
    }
}

final class WhiteDragonExpressions: NSObject {
    private static let size = NSSize(width: 162, height: 191)
    private static let pageSize = 6
    let window = PetPanel(size: size, level: .floating + 1)
    private let icons: [WhiteDragonExpression: NSImage]
    private let choices: [WhiteDragonExpression]
    private let content = NSView(frame: NSRect(origin: .zero, size: size))
    private var buttons: [DragonExpressionButton] = []
    private let previous = DragonPanelButton()
    private let next = DragonPanelButton()
    private var page = 0
    private var pageCount: Int { max(1, (choices.count + Self.pageSize - 1) / Self.pageSize) }
    var onSelect: ((WhiteDragonExpression) -> Void)?
    var onChange: (() -> Void)?

    init(icons: [WhiteDragonExpression: NSImage]) {
        self.icons = icons
        choices = WhiteDragonExpression.allCases.filter { icons[$0] != nil }
        super.init()
        window.title = "白龙表情"
        window.hasShadow = true
        window.ignoresMouseEvents = false
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
            button.action = #selector(turnPage(_:))
            content.addSubview(button)
        }
        render()
    }

    func show(near pet: NSRect, on screen: NSScreen?) {
        guard let screen, !choices.isEmpty else { return }
        let showing = !window.isVisible
        if showing, page != 0 {
            page = 0
            render()
        }
        let area = screen.visibleFrame.insetBy(dx: 5, dy: 5)
        let size = Self.size
        let right = pet.maxX + 3
        let left = pet.minX - size.width - 3
        let placeRight = right + size.width <= area.maxX
            || (left < area.minX && area.maxX - pet.maxX >= pet.minX - area.minX)
        let point = NSPoint(x: max(area.minX, min(placeRight ? right : left, area.maxX - size.width)),
                            y: max(area.minY, min(pet.midY - size.height / 2, area.maxY - size.height)))
        if window.frame.origin != point { window.setFrameOrigin(point) }
        if showing {
            window.orderFrontRegardless()
            onChange?()
        }
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        onChange?()
    }

    func changePage(by offset: Int) {
        let target = page + offset
        guard window.isVisible, (0..<pageCount).contains(target) else { return }
        page = target
        render()
        onChange?()
    }

    private func render() {
        for button in buttons { button.removeFromSuperview() }
        buttons = []
        for (slot, action) in choices.dropFirst(page * Self.pageSize).prefix(Self.pageSize).enumerated() {
            guard let icon = icons[action] else { continue }
            let frame = NSRect(x: 20 + (slot % 2) * 61, y: 7 + (2 - slot / 2) * 59, width: 61, height: 59)
            let button = DragonExpressionButton(expression: action, icon: icon, frame: frame)
            button.target = self
            button.action = #selector(select(_:))
            content.addSubview(button)
            buttons.append(button)
        }
        previous.isHidden = pageCount == 1
        next.isHidden = pageCount == 1
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < pageCount
        for arrow in [previous, next] {
            arrow.contentTintColor = NSColor(calibratedWhite: arrow.isEnabled ? 0.34 : 0.8, alpha: 1)
        }
    }

    @objc private func select(_ sender: DragonExpressionButton) { onSelect?(sender.expression) }
    @objc private func turnPage(_ sender: NSButton) { changePage(by: sender === next ? 1 : -1) }

    var status: [String: Any] {
        func values(_ rect: NSRect) -> [String: CGFloat] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        func bounds(_ button: NSButton) -> [String: CGFloat] {
            values(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        let items: [[String: Any]] = buttons.map { button in
            var item: [String: Any] = bounds(button)
            item["id"] = button.expression.rawValue
            item["pose"] = button.expression.rawValue
            item["title"] = button.title
            return item
        }
        return ["visible": window.isVisible, "windowNumber": window.windowNumber, "page": page + 1,
                "pageCount": pageCount, "frame": values(window.frame), "items": items,
                "previous": previous.isEnabled && !previous.isHidden ? bounds(previous) as Any : NSNull(),
                "next": next.isEnabled && !next.isHidden ? bounds(next) as Any : NSNull()]
    }
}
