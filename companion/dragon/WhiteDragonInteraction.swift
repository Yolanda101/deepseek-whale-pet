import AppKit
import Darwin

struct WhiteDragonInteraction: Decodable {
    enum Behavior: String, Decodable {
        case highfive, nuzzle, duet, beckon, starpass, chase
    }

    enum Role: String, Decodable { case initiator, partner }
    enum Phase: String { case waiting, approach, perform, recover, completed, cancelled }

    struct Point: Decodable {
        let x: Double
        let y: Double
        var value: NSPoint { NSPoint(x: x, y: y) }
    }

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var value: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    let id: UUID
    let behavior: Behavior
    let role: Role
    let startAt: TimeInterval
    let duration: TimeInterval
    let motionDuration: TimeInterval?
    let destination: Point
    let peer: Frame
    let dialogue: WhiteDragonDialogue?

    static func parse(_ json: String) -> Self? {
        guard json.utf8.count <= 4096,
              let request = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              request.startAt.isFinite, (1.5...(request.dialogue == nil ? 14 : 24)).contains(request.duration),
              request.destination.x.isFinite, request.destination.y.isFinite,
              request.peer.x.isFinite, request.peer.y.isFinite,
              (1...1024).contains(request.peer.width), (1...1024).contains(request.peer.height) else { return nil }
        if let motion = request.motionDuration, !(1.5...min(14, request.duration)).contains(motion) { return nil }
        if let dialogue = request.dialogue, !dialogue.isValid(for: request) { return nil }
        return request
    }

    var moveInterval: ClosedRange<Double>? {
        switch behavior {
        case .highfive: return 0...0.36
        case .nuzzle: return 0...0.38
        case .duet: return 0...0.31
        case .beckon: return role == .initiator ? nil : 0.24...0.65
        case .starpass: return nil
        case .chase: return role == .initiator ? 0.08...0.74 : 0.16...0.78
        }
    }

    var motionLength: TimeInterval { motionDuration ?? duration }

    func unitProgress(at time: TimeInterval) -> Double { (time - startAt) / motionLength }

    func phase(at progress: Double) -> Phase {
        if progress < 0 { return .waiting }
        if progress >= duration / motionLength { return .completed }
        if progress >= (behavior == .highfive || behavior == .nuzzle ? 0.84 : 0.88) { return .recover }
        if let moveInterval, progress < moveInterval.upperBound {
            if progress >= moveInterval.lowerBound { return .approach }
            return behavior == .beckon ? .perform : .waiting
        }
        return .perform
    }

    var voiceLine: String {
        switch behavior {
        case .highfive: return "击个掌，默契满分！"
        case .nuzzle: return "靠近一点，让我陪着你。"
        case .duet: return "跟上我的节拍，一起跳吧！"
        case .beckon: return "大肥鱼，来这边一起玩！"
        case .starpass: return "接好啦，这颗星星送给你！"
        case .chase: return "来追我呀，看看谁更快！"
        }
    }

    var voiceStart: Double {
        switch behavior {
        case .highfive, .nuzzle, .duet: return 0.35
        case .beckon, .chase: return 0.03
        case .starpass: return 0.11
        }
    }
}

struct WhiteDragonDialogue: Decodable {
    enum Speaker: String, Decodable { case dragon, whale }

    struct Turn: Decodable {
        let index: Int
        let speaker: Speaker
        let text: String
        let file: String
        let offset: TimeInterval
        let duration: TimeInterval
    }

    let script: String
    let turns: [Turn]
    let permitRequired: Bool?

    func isValid(for request: WhiteDragonInteraction) -> Bool {
        let initiator: Speaker = request.role == .initiator ? .dragon : .whale
        guard script == "\(request.behavior.rawValue)-\(initiator.rawValue)", turns.count == 3 else { return false }
        var earliestOffset: TimeInterval = 0
        for (index, turn) in turns.enumerated() {
            let expectedSpeaker: Speaker = index == 1 ? (initiator == .dragon ? .whale : .dragon) : initiator
            guard turn.index == index, turn.speaker == expectedSpeaker,
                  !turn.text.isEmpty, turn.text.count <= 80,
                  turn.file == "\(script)-\(index).wav",
                  turn.offset.isFinite, turn.offset >= earliestOffset,
                  (0.1...12).contains(turn.duration), turn.offset + turn.duration <= request.duration else { return false }
            earliestOffset = turn.offset + turn.duration + 0.20
        }
        return true
    }
}

struct WhiteDragonDialoguePermit {
    private struct Participant: Decodable, Equatable {
        let kind: WhiteDragonDialogue.Speaker
        let id: UUID
        let pid: pid_t
    }

    private struct Document: Decodable {
        enum Phase: String, Decodable { case preparing, committed }
        let id: UUID
        let phase: Phase
        let participants: [Participant]
    }

    private struct PeerStatus: Decodable {
        struct Scene: Decodable {
            let id: UUID
            let phase: String
        }
        let instanceID: UUID
        let pid: pid_t
        let interaction: Scene?
        let lastInteraction: Scene?
        let lastDialogue: Scene?
    }

    private let interactionID: UUID
    private let file: URL
    private let peerDirectory: URL
    private let own: Participant
    private let peer: Participant
    private var nextPeerCheck: TimeInterval = 0

    init?(interactionID: UUID, instanceID: UUID, directory: URL) {
        let instances = directory.deletingLastPathComponent()
        guard directory.isFileURL, UUID(uuidString: directory.lastPathComponent) == instanceID,
              instances.lastPathComponent == "Instances",
              Self.isDirectory(instances), Self.isDirectory(directory) else { return nil }
        let file = instances.deletingLastPathComponent().appendingPathComponent("dialogue-session.json")
        let own = Participant(kind: .dragon, id: instanceID, pid: ProcessInfo.processInfo.processIdentifier)
        guard let document = Self.read(Document.self, at: file), document.id == interactionID,
              document.participants.count == 2, document.participants.contains(own),
              let peer = document.participants.first(where: { $0.kind == .whale }),
              peer.id != own.id, peer.pid > 1, peer.pid != own.pid else { return nil }
        self.interactionID = interactionID
        self.file = file
        self.own = own
        self.peer = peer
        peerDirectory = instances.appendingPathComponent(peer.id.uuidString, isDirectory: true)
    }

    mutating func allows(for request: WhiteDragonInteraction, at timestamp: TimeInterval, beforeSpeech: Bool = false) -> Bool {
        guard let document = Self.read(Document.self, at: file), document.id == interactionID,
              document.participants.count == 2,
              document.participants.contains(own), document.participants.contains(peer) else { return false }
        if timestamp < request.startAt { return true }
        guard document.phase == .committed else { return false }
        guard beforeSpeech || timestamp >= nextPeerCheck else { return true }
        nextPeerCheck = timestamp + 0.08
        guard kill(peer.pid, 0) == 0, Self.isDirectory(peerDirectory),
              let status = Self.read(PeerStatus.self, at: peerDirectory.appendingPathComponent("status.json")),
              status.instanceID == peer.id, status.pid == peer.pid else { return false }
        if let last = status.lastDialogue, last.id == interactionID,
           last.phase == "cancelled" || last.phase == "failed" { return false }
        if status.interaction?.id == interactionID { return true }
        return !beforeSpeech && timestamp >= request.startAt + request.duration - 0.04
            && status.lastInteraction?.id == interactionID && status.lastInteraction?.phase == "completed"
            && status.lastDialogue?.id == interactionID && status.lastDialogue?.phase == "completed"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let limit = 128 * 1024
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              (1...Int64(limit)).contains(details.st_size),
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct WhiteDragonDialogueLibrary: Decodable {
    struct Script: Decodable {
        struct Line: Decodable {
            let index: Int
            let speaker: WhiteDragonDialogue.Speaker
            let text: String
            let file: String
            let duration: TimeInterval

            func matches(_ turn: WhiteDragonDialogue.Turn) -> Bool {
                index == turn.index && speaker == turn.speaker && text == turn.text && file == turn.file
                    && abs(duration - turn.duration) <= 0.0001
            }
        }

        let behavior: WhiteDragonInteraction.Behavior
        let initiator: WhiteDragonDialogue.Speaker
        let turns: [Line]
    }

    let version: Int
    let scripts: [String: Script]

    func contains(_ dialogue: WhiteDragonDialogue) -> Bool {
        guard version == 1, let script = scripts[dialogue.script],
              dialogue.script == "\(script.behavior.rawValue)-\(script.initiator.rawValue)",
              script.turns.count == dialogue.turns.count else { return false }
        return zip(script.turns, dialogue.turns).allSatisfy { $0.0.matches($0.1) }
    }
}

struct ActiveWhiteDragonInteraction {
    let request: WhiteDragonInteraction
    let origin: NSPoint
    let destination: NSPoint
    var phase = WhiteDragonInteraction.Phase.waiting
    var voiceStarted = false

    func position(at progress: Double) -> NSPoint {
        guard let interval = request.moveInterval else { return origin }
        let t = min(1, max(0, (progress - interval.lowerBound) / (interval.upperBound - interval.lowerBound)))
        let smooth = t * t * (3 - 2 * t)
        var position = NSPoint(x: origin.x + (destination.x - origin.x) * smooth,
                               y: origin.y + (destination.y - origin.y) * smooth)
        if request.behavior == .chase {
            position.y += sin(t * .pi * 2) * sin(t * .pi) * 15
        }
        return position
    }

    func animation(at progress: Double, peerOnLeft: Bool) -> String {
        if let interval = request.moveInterval, interval.contains(progress),
           hypot(destination.x - origin.x, destination.y - origin.y) > 3 {
            return destination.x < origin.x ? "running-left" : "running-right"
        }
        switch request.phase(at: progress) {
        case .waiting, .recover, .completed, .cancelled: return "idle"
        case .approach, .perform:
            switch request.behavior {
            case .highfive: return (0.40...0.70).contains(progress) ? "jumping" : "waving"
            case .nuzzle: return request.role == .initiator ? "waiting" : "idle"
            case .duet: return "dance"
            case .beckon: return request.role == .initiator ? "waving" : (progress >= 0.65 ? "jumping" : "waiting")
            case .starpass:
                return request.role == .initiator ? (progress >= 0.18 ? "waving" : "waiting")
                    : (progress >= 0.62 ? "jumping" : "waiting")
            case .chase: return progress >= 0.74 ? "jumping" : (peerOnLeft ? "running-left" : "running-right")
            }
        }
    }
}

final class DragonEffectOverlay {
    private let canvas = DragonEffectView(frame: NSRect(x: 0, y: 0, width: 45, height: 45))
    private lazy var panel: PetPanel = {
        let panel = PetPanel(size: canvas.bounds.size, level: .floating + 1)
        panel.title = "白龙动作效果"
        panel.contentView = canvas
        return panel
    }()

    var visible: Bool { panel.isVisible }
    var name: String? { visible ? canvas.symbol : nil }

    func show(_ symbol: String, point: NSPoint, progress: Double, intensity: Double = 1) {
        canvas.symbol = symbol
        canvas.progress = progress
        canvas.intensity = intensity
        canvas.needsDisplay = true
        panel.setFrameOrigin(NSPoint(x: point.x - canvas.bounds.midX, y: point.y - canvas.bounds.midY))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private final class DragonEffectView: NSView {
    var symbol = ""
    var progress: Double = 0
    var intensity: Double = 1

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(max(0, min(1, intensity)))
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: sin(progress * .pi * 2) * 0.15)
        let size = 22 + 3 * sin(progress * .pi)
        let label = symbol as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
        let bounds = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: -bounds.width / 2, y: -bounds.height / 2), withAttributes: attributes)
    }
}
