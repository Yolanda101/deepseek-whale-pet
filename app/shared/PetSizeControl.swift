import AppKit

private final class PixelSlider: NSSlider {
    override func keyDown(with event: NSEvent) {
        let next: Double
        switch event.keyCode {
        case 123, 125: next = doubleValue - 1
        case 124, 126: next = doubleValue + 1
        case 115: next = minValue
        case 119: next = maxValue
        default: super.keyDown(with: event); return
        }
        doubleValue = min(maxValue, max(minValue, next.rounded()))
        _ = sendAction(action, to: target)
    }
}

final class PetSizeControl: NSView {
    let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let changed: (Int) -> Void

    init(width: Int, minimum: Int, maximum: Int, changed: @escaping (Int) -> Void) {
        self.changed = changed
        slider = PixelSlider(value: Double(width), minValue: Double(minimum), maxValue: Double(maximum),
                             target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 57))
        let label = NSTextField(labelWithString: "单独调整伴侣")
        label.frame = NSRect(x: 18, y: 33, width: 125, height: 18)
        label.font = .menuFont(ofSize: 13)
        valueLabel.frame = NSRect(x: 145, y: 33, width: 68, height: 18)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        slider.frame = NSRect(x: 16, y: 6, width: 200, height: 22)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        slider.setAccessibilityLabel("伴侣大小")
        addSubview(label)
        addSubview(valueLabel)
        addSubview(slider)
        displayValue(width)
    }

    required init?(coder: NSCoder) { nil }

    private func displayValue(_ width: Int) { valueLabel.stringValue = "\(width) px" }

    @objc private func slid() {
        let width = Int(slider.doubleValue.rounded())
        slider.doubleValue = Double(width)
        displayValue(width)
        changed(width)
    }
}
