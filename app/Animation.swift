import AppKit
import ImageIO

enum Skin: String, CaseIterable {
    case figurine
    case original

    // Migrate the preferred appearance and accept commands issued by older shortcuts.
    init?(selection: String) {
        if selection == "model" { self = .figurine }
        else { self.init(rawValue: selection) }
    }

    var title: String {
        switch self {
        case .figurine: return "Q 版手办"
        case .original: return "原版动画"
        }
    }
}

enum Pose: String, CaseIterable {
    case idle, work, walkLeft, walkRight, greeting, dance, playful, feeding, tailwag, angry, dizzy, hungry, outing, crying, rice, remorse, drag

    static let actions: [Self] = [.greeting, .dance, .playful, .feeding, .tailwag, .angry, .dizzy, .hungry, .outing, .crying, .rice, .remorse]
    static let expressions: [Self] = [.greeting, .playful, .dance, .angry, .dizzy, .hungry, .tailwag, .feeding, .outing, .crying, .rice, .remorse]

    var expressionTitle: String {
        switch self {
        case .angry: return "气鼓鼓"
        case .remorse: return "很愧疚"
        default: return actionTitle
        }
    }

    static let required: [Self] = [.idle, .work, .walkLeft, .walkRight, .greeting, .dance, .playful, .feeding]

    var actionTitle: String {
        switch self {
        case .greeting: return "打招呼"
        case .dance: return "跳舞"
        case .playful: return "撒娇"
        case .feeding: return "喂鱼"
        case .tailwag: return "甩尾巴"
        case .angry: return "气鼓鼓甩尾"
        case .dizzy: return "累晕了"
        case .hungry: return "讨饭吃"
        case .outing: return "想出门玩"
        case .crying: return "伤心掉眼泪"
        case .rice: return "吃大白饭"
        case .remorse: return "犯错后很愧疚"
        default: return rawValue
        }
    }
}

struct AlphaMask {
    private static let side = 48
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let pixels: [UInt8]

    init?(_ image: CGImage) {
        let side = Self.side
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: Self.colorSpace, bitmapInfo: format),
              let base = context.data else { return nil }
        let area = CGRect(x: 0, y: 0, width: side, height: side)
        context.clear(area)
        context.interpolationQuality = .medium
        context.draw(image, in: area)
        let rgba = base.assumingMemoryBound(to: UInt8.self)
        pixels = withExtendedLifetime(context) {
            stride(from: 3, to: side * side * 4, by: 4).map { rgba[$0] }
        }
    }

    func contains(x: CGFloat, y: CGFloat) -> Bool {
        guard (0..<1).contains(x), (0..<1).contains(y) else { return false }
        let side = Self.side
        let row = side - 1 - Int(y * CGFloat(side))
        return pixels[row * side + Int(x * CGFloat(side))] >= 45
    }

    var hasTransparency: Bool {
        pixels.contains { $0 <= 8 } && pixels.contains { $0 >= 240 }
    }
}

struct AnimationFrame {
    let image: CGImage
    let alpha: AlphaMask

    init?(_ url: URL) {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              let alpha = AlphaMask(image) else { return nil }
        self.image = image
        self.alpha = alpha
    }
}

final class Clip {
    let frames: [AnimationFrame]
    private let frameEnds: [TimeInterval]
    var duration: TimeInterval { frameEnds.last! }
    func endTime(ofFrame index: Int) -> TimeInterval { frameEnds[index] }
    var footprint: Int { frames.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height } }

    init?(files: [URL], fps: TimeInterval, frameDurationsMs: [Double]?) {
        let frames = files.compactMap { url in autoreleasepool { AnimationFrame(url) } }
        guard frames.count >= 2, frames.count == files.count else { return nil }
        self.frames = frames
        if let times = frameDurationsMs {
            guard times.count == files.count, times.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            var total = 0.0
            frameEnds = times.map { total += $0 / 1000; return total }
        } else {
            frameEnds = (1...files.count).map { Double($0) / fps }
        }
    }

    func index(at time: TimeInterval, loop: Bool) -> Int {
        let elapsed = max(0, time)
        let position = loop ? elapsed.truncatingRemainder(dividingBy: duration) : elapsed
        return frameEnds.firstIndex { position < $0 } ?? frames.count - 1
    }
}

final class AnimationLibrary {
    private struct SkinFiles {
        let fps: Double
        let clips: [Pose: [URL]]
        let timings: [Pose: [Double]]
    }

    private let sources: [Skin: SkinFiles]
    private let cache = NSCache<NSString, Clip>()
    private let worker = DispatchQueue(label: "com.local.deepseek.whalepet.frames", qos: .userInitiated)
    private var pending: [String: [(Clip?) -> Void]] = [:]
    var skins: [Skin] { Skin.allCases.filter { sources[$0] != nil } }

    init(resources: URL) {
        let directory = resources.appendingPathComponent("Frames", isDirectory: true)
        let fm = FileManager.default
        var sources: [Skin: SkinFiles] = [:]
        for skin in Skin.allCases {
            let root = directory.appendingPathComponent(skin.rawValue, isDirectory: true)
            let manifest = root.appendingPathComponent("manifest.json")
            let data = try? Data(contentsOf: manifest)
            let metadata = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let configuredFPS = metadata?["fps"] as? Double ?? 24
            let fps = (1...60).contains(configuredFPS) ? configuredFPS : 24
            let stateInfo = metadata?["states"] as? [String: [String: Any]]
            var timings: [Pose: [Double]] = [:]
            var clips: [Pose: [URL]] = [:]
            for pose in Pose.allCases {
                let folder = root.appendingPathComponent(pose.rawValue, isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                let frames = files.filter { $0.pathExtension.lowercased() == "png" }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                guard frames.count > 1 else { continue }
                if let times = stateInfo?[pose.rawValue]?["frameDurationsMs"] as? [Double] {
                    guard times.count == frames.count, times.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
                    timings[pose] = times
                }
                clips[pose] = frames
            }
            if Pose.required.allSatisfy({ clips[$0] != nil }) {
                sources[skin] = SkinFiles(fps: fps, clips: clips, timings: timings)
            }
        }
        self.sources = sources
        cache.totalCostLimit = 80 * 1024 * 1024
        cache.countLimit = 5
    }

    func supports(_ pose: Pose, skin: Skin) -> Bool { sources[skin]?.clips[pose] != nil }

    // The main thread owns in-flight callbacks. Decoding precedes playback so
    // expensive PNG reads never interrupt a displayed animation.
    func load(_ pose: Pose, skin: Skin, completion: @escaping (Clip?) -> Void) {
        guard let source = sources[skin], let files = source.clips[pose] else {
            completion(nil)
            return
        }
        let key = skin.rawValue + "/" + pose.rawValue
        if let clip = cache.object(forKey: key as NSString) {
            completion(clip)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        worker.async { [self] in
            let clip = Clip(files: files, fps: source.fps, frameDurationsMs: source.timings[pose])
            DispatchQueue.main.async { [self] in
                if let clip { cache.setObject(clip, forKey: key as NSString, cost: clip.footprint) }
                let callbacks = pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(clip) }
            }
        }
    }

    func verify() throws -> [String: [String: Int]] {
        guard sources[.original] != nil, Pose.actions.allSatisfy({ supports($0, skin: .figurine) }) else {
            throw AssetError("桌宠动画不完整")
        }
        var report: [String: [String: Int]] = [:]
        for skin in skins {
            guard let source = sources[skin] else { continue }
            var counts: [String: Int] = [:]
            var canvas: Int?
            for (pose, files) in source.clips {
                var signatures = Set<Data>()
                for url in files {
                    try autoreleasepool {
                        guard let frame = AnimationFrame(url), frame.image.width == frame.image.height,
                              frame.image.width >= 128, frame.alpha.hasTransparency,
                              canvas == nil || frame.image.width == canvas else {
                            throw AssetError("无效的透明动画帧 \(skin.rawValue)/\(pose.rawValue)/\(url.lastPathComponent)")
                        }
                        canvas = frame.image.width
                        if signatures.count < 2 { signatures.insert(try Data(contentsOf: url)) }
                    }
                }
                guard signatures.count == 2 else { throw AssetError("动画帧没有变化 \(skin.rawValue)/\(pose.rawValue)") }
                counts[pose.rawValue] = files.count
            }
            if let canvas { counts["canvas"] = canvas }
            counts["fps"] = Int(source.fps)
            report[skin.rawValue] = counts
        }
        return report
    }
}

struct AssetError: LocalizedError {
    let errorDescription: String?
    init(_ error: String) { errorDescription = error }
}
