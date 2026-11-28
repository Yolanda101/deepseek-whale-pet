import AppKit

enum SocialBehavior: String, CaseIterable {
    case highfive, nuzzle, duet, beckon, starpass, chase
    var title: String {
        switch self {
        case .highfive: return "击掌"
        case .nuzzle: return "贴贴"
        case .duet: return "双人舞"
        case .beckon: return "招手跑来"
        case .starpass: return "抛接星星"
        case .chase: return "追逐玩耍"
        }
    }
    var shortDistance: Bool { [.highfive, .nuzzle, .duet].contains(self) }
}

struct PairInteractionPlan {
    let id = UUID()
    let behavior: SocialBehavior
    let startAt: TimeInterval
    private(set) var duration: TimeInterval
    let motionDuration: TimeInterval
    private var dialogue: DialogueSchedule?
    var dialogueScript: String? { dialogue?.script }
    let origins: [NSRect]
    let destinations: [NSPoint]
    let initiator: Int

    static func gap(_ first: NSRect, _ second: NSRect) -> CGFloat {
        hypot(max(0, abs(first.midX - second.midX) - (first.width + second.width) / 2),
              max(0, abs(first.midY - second.midY) - (first.height + second.height) / 2))
    }

    init(behavior: SocialBehavior, first: NSRect, second: NSRect, screen: NSRect,
         initiator: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.behavior = behavior
        self.initiator = initiator
        let rects = [first, second]
        origins = rects
        startAt = now + 1.2
        var points = [NSPoint(x: first.midX, y: first.midY), NSPoint(x: second.midX, y: second.midY)]
        func fit(_ point: NSPoint, index: Int) -> NSPoint {
            let size = rects[index].size
            return NSPoint(x: min(screen.maxX - size.width / 2, max(screen.minX + size.width / 2, point.x)),
                           y: min(screen.maxY - size.height / 2, max(screen.minY + size.height / 2, point.y)))
        }
        if behavior.shortDistance {
            let overlap: CGFloat = behavior == .nuzzle ? -0.35 : behavior == .highfive ? -0.22 : 0.10
            let gap = min(first.width, second.width) * overlap
            let total = first.width + second.width + gap
            let midpoint = (first.midX + second.midX) / 2
            let left = min(screen.maxX - total - 8, max(screen.minX + 8, midpoint - total / 2))
            let floor = max(screen.minY + 8, min(screen.maxY - max(first.height, second.height) - 8,
                                               (first.minY + second.minY) / 2))
            let leftIndex = first.midX <= second.midX ? 0 : 1
            let rightIndex = 1 - leftIndex
            points[leftIndex] = NSPoint(x: left + rects[leftIndex].width / 2,
                                       y: floor + rects[leftIndex].height / 2)
            points[rightIndex] = NSPoint(x: left + rects[leftIndex].width + gap + rects[rightIndex].width / 2,
                                        y: floor + rects[rightIndex].height / 2)
        } else if behavior == .beckon {
            let partner = 1 - initiator
            let leader = rects[initiator]
            let separation = (leader.width + rects[partner].width) / 2 - min(leader.width, rects[partner].width) * 0.12
            let direction: CGFloat = points[partner].x < points[initiator].x ? -1 : 1
            let preferred = NSPoint(x: leader.midX + direction * separation,
                                    y: leader.minY + rects[partner].height / 2)
            let other = NSPoint(x: leader.midX - direction * separation, y: preferred.y)
            points[partner] = abs(fit(preferred, index: partner).x - preferred.x) < 1 ? preferred : other
        } else if behavior == .chase {
            let partner = 1 - initiator
            let leader = rects[initiator]
            let rightSpace = screen.maxX - leader.maxX - 12
            let leftSpace = leader.minX - screen.minX - 12
            let direction: CGFloat = leader.midX >= rects[partner].midX ? 1 : -1
            let travel = min(360, direction > 0 ? rightSpace : leftSpace)
            points[initiator].x += direction * max(0, travel)
            points[partner] = NSPoint(x: leader.midX, y: leader.minY + rects[partner].height / 2)
        }
        // Star passing keeps both partners in place. Every other destination stays on the same display.
        destinations = points.enumerated().map { fit($0.element, index: $0.offset) }
        let travel = zip(rects, destinations).map { hypot($0.0.midX - $0.1.x, $0.0.midY - $0.1.y) }.max() ?? 0
        let minimum: Double = behavior == .duet ? 8 : behavior == .chase ? 9 : 6.5
        motionDuration = min(14, max(minimum, Double(travel) / 145 / 0.5 + 2))
        duration = motionDuration
        dialogue = nil
    }

    private struct DialogueTurn: Codable {
        let index: Int
        let speaker: String
        let text: String
        let file: String
        let duration: Double
        var offset: Double = 0
        enum CodingKeys: String, CodingKey { case index, speaker, text, file, duration, offset }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            index = try values.decode(Int.self, forKey: .index)
            speaker = try values.decode(String.self, forKey: .speaker)
            text = try values.decode(String.self, forKey: .text)
            file = try values.decode(String.self, forKey: .file)
            duration = try values.decode(Double.self, forKey: .duration)
            offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        }
    }
    private struct DialogueScript: Decodable {
        let behavior: String
        let initiator: String
        let turns: [DialogueTurn]
    }
    private struct DialogueCatalog: Decodable {
        let version: Int
        let scripts: [String: DialogueScript]
    }
    private struct DialogueSchedule: Encodable {
        let script: String
        let turns: [DialogueTurn]
        var permitRequired = true
    }
    mutating func addDialogue(resources: URL) throws {
        let file = resources.appendingPathComponent("Dialogue/manifest.json")
        let catalog = try JSONDecoder().decode(DialogueCatalog.self, from: Data(contentsOf: file))
        let speaker = initiator == 0 ? "dragon" : "whale"
        let name = behavior.rawValue + "-" + speaker
        guard catalog.version == 1, let script = catalog.scripts[name], script.behavior == behavior.rawValue,
              script.initiator == speaker, script.turns.count == 3,
              script.turns.map(\.index) == [0, 1, 2],
              script.turns.map(\.speaker) == [speaker, speaker == "dragon" ? "whale" : "dragon", speaker],
              script.turns.allSatisfy({ $0.duration.isFinite && (0.2...6).contains($0.duration) &&
                  !$0.text.isEmpty && URL(fileURLWithPath: $0.file).lastPathComponent == $0.file }) else {
            throw NSError(domain: "DesktopPetStudio.Dialogue", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "互动台词资源不完整，请重新安装桌宠伙伴。"])
        }
        let responsePhase: Double
        switch behavior {
        case .highfive: responsePhase = 0.54
        case .nuzzle: responsePhase = 0.45
        case .duet: responsePhase = 0.47
        case .beckon: responsePhase = 0.65
        case .starpass: responsePhase = 0.69
        case .chase: responsePhase = 0.78
        }
        var turns = script.turns
        turns[0].offset = 0.05
        turns[1].offset = max(responsePhase * motionDuration, turns[0].offset + turns[0].duration + 0.28)
        turns[2].offset = turns[1].offset + turns[1].duration + 0.28
        let finalEnd = turns[2].offset + turns[2].duration + 0.55
        guard finalEnd <= 24 else {
            throw NSError(domain: "DesktopPetStudio.Dialogue", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "互动对白太长，请检查语音素材。"])
        }
        duration = max(motionDuration, finalEnd)
        dialogue = DialogueSchedule(script: name, turns: turns)
    }

    func payload(for index: Int) throws -> String {
        let peer = origins[1 - index]
        let point = destinations[index]
        var values: [String: Any] = [
            "id": id.uuidString, "behavior": behavior.rawValue,
            "role": index == initiator ? "initiator" : "partner",
            "startAt": startAt, "duration": duration, "motionDuration": motionDuration,
            "destination": ["x": point.x, "y": point.y],
            "peer": ["x": peer.minX, "y": peer.minY, "width": peer.width, "height": peer.height],
        ]
        if let dialogue {
            let encoded = try JSONEncoder().encode(dialogue)
            values["dialogue"] = try JSONSerialization.jsonObject(with: encoded)
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        return String(decoding: data, as: UTF8.self)
    }
}
