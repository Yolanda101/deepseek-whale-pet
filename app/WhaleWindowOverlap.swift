import AppKit

// The two pets run in different processes. Resolve their order only when the
// pointer can actually touch both, since the Mini backing window is much larger than its art.
final class WhaleWindowOverlap {
    private let storage: Storage
    private var report: [String: Any] = [:]
    private var nextRead = 0.0
    private var clipKey = ""
    private var clip: Clip?
    private var order: (target: Int, companion: Int, expires: TimeInterval, above: Bool)?

    init(storage: Storage) { self.storage = storage }

    private func snapshot() -> [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRead {
            nextRead = now + 0.25
            report = storage.isRunning ? storage.snapshot() : [:]
        }
        return report
    }

    private func rect(_ value: Any?) -> CGRect? {
        guard let r = value as? [String: Double], let x = r["x"], let y = r["y"],
              let w = r["width"], let h = r["height"], w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func nativeCovers(_ point: NSPoint, companionWindow: Int, mask: AlphaMask) -> Bool {
        let status = snapshot()
        guard status["targetVisible"] as? Bool == true,
              let box = rect(status["targetFrame"]), box.contains(point),
              let target = status["targetWindowNumber"] as? Int,
              mask.contains(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let order, order.target == target, order.companion == companionWindow, order.expires > now {
            return order.above
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let ids = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
        guard let a = ids.firstIndex(of: target), let b = ids.firstIndex(of: companionWindow) else { return false }
        order = (target, companionWindow, now + 0.10, a < b)
        return a < b
    }

    func companionHit(at point: NSPoint, library: AnimationLibrary) -> (windowNumber: Int, opaque: Bool)? {
        let status = snapshot()
        guard status["visible"] as? Bool == true, let number = status["windowNumber"] as? Int,
              let pos = status["position"] as? [String: Double], let x = pos["x"], let y = pos["y"],
              let width = status["petWidth"] as? Double, width > 0,
              CGRect(x: x, y: y, width: width, height: width).contains(point),
              let skinName = status["shownSkin"] as? String, let skin = Skin(rawValue: skinName),
              let poseName = status["pose"] as? String, let pose = Pose(rawValue: poseName) else { return nil }
        let key = skinName + "/" + poseName
        if clipKey != key {
            clipKey = key
            clip = nil
            library.load(pose, skin: skin) { [weak self] loaded in
                if self?.clipKey == key { self?.clip = loaded }
            }
        }
        guard let frames = clip?.frames, let index = status["frameIndex"] as? Int, frames.indices.contains(index)
            else { return (number, NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == number) }
        return (number, frames[index].alpha.contains(x: (point.x - x) / width, y: (point.y - y) / width))
    }
}
