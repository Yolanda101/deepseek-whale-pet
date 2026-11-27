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

struct Storage {
    let directory: URL
    var commandScope: String { directory.path }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }
    private var prefsURL: URL { directory.appendingPathComponent("preferences.json") }
    private var mutexURL: URL { directory.appendingPathComponent("instance.lock") }

    init(directory: URL) {
        self.directory = directory
    }

    init() {
        if let path = ProcessInfo.processInfo.environment["WHALE_PET_DATA_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = parent.appendingPathComponent("DeepSeekWhalePet", isDirectory: true)
        }
    }

    var nativeExpressions: Storage {
        Storage(directory: directory.appendingPathComponent("CodexExpressions", isDirectory: true))
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
