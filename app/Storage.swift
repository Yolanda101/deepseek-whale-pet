import Darwin
import Foundation

let bundleIdentity = "com.local.deepseek.whalepet"
let commandNotification = Notification.Name(bundleIdentity + ".command")
let preferencesNotification = Notification.Name(bundleIdentity + ".preferences")

struct Preferences: Codable {
    var hidden = false
    var roaming = true
    var muted = false
    var completionVoice = false
    var skin: String?
    var independentWidth: Int?
    var position: Position?

    struct Position: Codable {
        var x: Double
        var y: Double
    }
}

struct WhaleInteraction: Decodable, Equatable {
    enum Behavior: String, Decodable {
        case highfive, nuzzle, duet, beckon, starpass, chase
    }

    enum Role: String, Decodable {
        case initiator, partner
    }

    struct Point: Decodable, Equatable {
        let x: Double
        let y: Double

        var location: CGPoint { CGPoint(x: x, y: y) }
        var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 100_000 && abs(y) <= 100_000 }
    }

    struct Peer: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var isValid: Bool {
            Point(x: x, y: y).isValid && width.isFinite && height.isFinite &&
                (1...1024).contains(width) && (1...1024).contains(height)
        }
    }

    let id: UUID
    let behavior: Behavior
    let role: Role
    let startAt: TimeInterval
    let duration: TimeInterval
    let motionDuration: TimeInterval?
    let destination: Point
    let peer: Peer
    let dialogue: WhaleDialogueRequest?

    var movementDuration: TimeInterval { motionDuration ?? duration }

    static func parse(_ argument: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Self? {
        guard let argument, argument.utf8.count <= 4096,
              let interaction = try? JSONDecoder().decode(Self.self, from: Data(argument.utf8)),
              interaction.startAt.isFinite, interaction.duration.isFinite,
              (now - 0.25...now + 10).contains(interaction.startAt),
              (1.5...24).contains(interaction.duration),
              (1.5...interaction.duration).contains(interaction.movementDuration),
              interaction.dialogue?.fits(sceneDuration: interaction.duration) != false,
              interaction.destination.isValid, interaction.peer.isValid else { return nil }
        return interaction
    }
}

struct WhaleDialoguePermit {
    enum Phase: String, Decodable { case preparing, committed }

    private struct Permit: Decodable {
        struct Participant: Decodable, Equatable {
            let kind: WhaleDialogueRequest.Speaker
            let id: UUID
            let pid: Int32
        }

        let id: UUID
        let phase: Phase
        let participants: [Participant]
    }

    private struct PeerStatus: Decodable {
        struct Interaction: Decodable {
            let id: UUID
            let phase: String
        }

        let instanceID: UUID
        let pid: Int32
        let interaction: Interaction?
        let lastInteraction: Interaction?
        let lastDialogue: Interaction?
    }

    private let file: URL
    private let peerDirectory: URL
    private let own: Permit.Participant
    private let peer: Permit.Participant

    init?(interactionID: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard env["DESKTOP_PET_MANAGED"] == "1", let path = env["DESKTOP_PET_INSTANCE_DIR"], path.hasPrefix("/"),
              let rawID = env["DESKTOP_PET_INSTANCE_ID"], let id = UUID(uuidString: rawID) else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let instances = directory.deletingLastPathComponent()
        guard instances.lastPathComponent == "Instances", UUID(uuidString: directory.lastPathComponent) == id,
              Self.isDirectory(instances), Self.isDirectory(directory) else { return nil }
        let file = instances.deletingLastPathComponent().appendingPathComponent("dialogue-session.json")
        let own = Permit.Participant(kind: .whale, id: id, pid: ProcessInfo.processInfo.processIdentifier)
        guard let permit = Self.read(Permit.self, at: file), permit.id == interactionID, permit.participants.count == 2,
              permit.participants.contains(own), let peer = permit.participants.first(where: { $0.kind == .dragon }),
              peer.id != own.id, peer.pid > 1, peer.pid != own.pid else { return nil }
        self.file = file
        self.own = own
        self.peer = peer
        peerDirectory = instances.appendingPathComponent(peer.id.uuidString, isDirectory: true)
    }

    func phase(for request: WhaleInteraction) -> Phase? {
        guard let permit = Self.read(Permit.self, at: file), permit.id == request.id, permit.participants.count == 2,
              permit.participants.contains(own), permit.participants.contains(peer) else { return nil }
        guard permit.phase == .committed else { return .preparing }
        let status = peerDirectory.appendingPathComponent("status.json")
        guard kill(peer.pid, 0) == 0, Self.isDirectory(peerDirectory), let report = Self.read(PeerStatus.self, at: status),
              report.instanceID == peer.id, report.pid == peer.pid else { return nil }
        if let last = report.lastDialogue, last.id == request.id {
            if last.phase == "cancelled" || last.phase == "failed" { return nil }
            if last.phase == "completed", report.lastInteraction?.id == request.id,
               report.lastInteraction?.phase == "completed",
               ProcessInfo.processInfo.systemUptime >= request.startAt + request.duration - 0.08 {
                return .committed
            }
        }
        return report.interaction?.id == request.id ? .committed : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return info.isDirectory == true && info.isSymbolicLink != true
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var details = stat()
        let limit = 128 * 1024
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              (1...Int64(limit)).contains(details.st_size),
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct Storage {
    let directory: URL
    let instanceID: String?
    var commandScope: String { directory.path }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }
    private var prefsURL: URL { directory.appendingPathComponent("preferences.json") }
    private var mutexURL: URL { directory.appendingPathComponent("instance.lock") }

    init(directory: URL, instanceID: String? = nil) {
        self.directory = directory
        self.instanceID = instanceID
    }

    init() {
        if let path = ProcessInfo.processInfo.environment["WHALE_PET_DATA_DIR"], !path.isEmpty {
            self.init(directory: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        } else {
            self.init(directory: Self.defaultDirectory)
        }
    }

    static func companion() throws -> Storage {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DESKTOP_PET_MANAGED"] == "1" else { return Storage() }
        guard let id = environment["DESKTOP_PET_INSTANCE_ID"], UUID(uuidString: id) != nil,
              let path = environment["DESKTOP_PET_INSTANCE_DIR"], path.hasPrefix("/") else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "受管理的大肥鱼需要有效的实例编号和绝对目录。",
            ])
        }
        return Storage(directory: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, instanceID: id)
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeepSeekWhalePet", isDirectory: true)
    }

    var nativeExpressions: Storage {
        let companionDirectory = instanceID == nil ? directory : Self.defaultDirectory
        return Storage(directory: companionDirectory.appendingPathComponent("CodexExpressions", isDirectory: true))
    }

    func claim() throws -> Int32? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(mutexURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw storageError() }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let reason = errno
        close(fd)
        if reason == EWOULDBLOCK { return nil }
        throw storageError(reason)
    }

    var isRunning: Bool {
        let fd = open(mutexURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) == -1 && errno == EWOULDBLOCK
    }

    private func storageError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: mutexURL.path])
    }

    func preferences() -> Preferences {
        guard let data = try? Data(contentsOf: prefsURL),
              let settings = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return settings
    }

    func save(_ settings: Preferences) {
        do {
            try JSONEncoder().encode(settings).write(to: prefsURL, options: .atomic)
        } catch {
            NSLog("无法保存大肥鱼偏好 %@", error.localizedDescription)
        }
    }

    func snapshot() -> [String: Any] {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return status
    }

    func write(_ report: [String: Any]) {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try bytes.write(to: statusURL, options: .atomic)
        } catch {
            NSLog("无法保存大肥鱼状态 %@", error.localizedDescription)
        }
    }

    func send(_ action: String, argument: String? = nil) -> [String: Any]? {
        guard isRunning else { return nil }
        let token = UUID().uuidString
        var command = ["command": action, "request": token]
        command["argument"] = argument
        DistributedNotificationCenter.default().postNotificationName(
            commandNotification, object: commandScope, userInfo: command, deliverImmediately: true
        )
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let report = snapshot()
            if (report["lastCommand"] as? [String: Any])?["request"] as? String == token {
                return report
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return nil
    }
}
