import Darwin
import Foundation
import SQLite3

final class ActivityMonitor {
    private let queue = DispatchQueue(label: "com.local.deepseek.whalepet.activity", qos: .utility)
    private let activity: CodexActivity
    private var timer: DispatchSourceTimer?

    init(codexHome: URL = ActivityMonitor.defaultCodexHome) {
        activity = CodexActivity(home: codexHome)
    }

    static var defaultCodexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func start(onChange: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(300))
            var lastValue: Bool?
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let value = self.activity.isActive()
                guard value != lastValue else { return }
                lastValue = value
                DispatchQueue.main.async { onChange(value) }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func probeActivity(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let value = activity.isActive()
            DispatchQueue.main.async { completion(value) }
        }
    }

    deinit {
        timer?.cancel()
    }
}

private final class CodexActivity {
    private let historyURL: URL
    private let locksURL: URL
    private let rollouts: RecentRollouts
    private let secondsPerClockTick: TimeInterval
    private var history: TurnHistory?

    init(home: URL) {
        historyURL = home.appendingPathComponent("thread_history_1.sqlite")
        locksURL = home.appendingPathComponent("thread-writer-locks", isDirectory: true)
        rollouts = RecentRollouts(root: home.appendingPathComponent("sessions", isDirectory: true))
        var clock = mach_timebase_info_data_t()
        mach_timebase_info(&clock)
        secondsPerClockTick = TimeInterval(clock.numer) / TimeInterval(clock.denom) / 1_000_000_000
    }

    func isActive() -> Bool {
        let now = Date()
        // The continuous clock includes system sleep. A task can legitimately
        // hold its writer lock before and after a sleep or wake cycle.
        let boot = now.addingTimeInterval(-TimeInterval(mach_continuous_time()) * secondsPerClockTick)
        guard let liveWriters = writerLocks() else {
            return rollouts.active(now: now, boot: boot, writers: nil)
        }

        guard !liveWriters.isEmpty else { return false }
        let store = openHistory()
        var unprojectedWriters: [String: Date] = [:]
        for (id, acquired) in liveWriters {
            switch store?.latestTurn(threadID: id) {
            case let .started(started):
                if started >= max(boot, acquired).addingTimeInterval(-3), started <= now.addingTimeInterval(3) {
                    return true
                }
            case .ended:
                break
            case .unavailable, nil:
                unprojectedWriters[id] = acquired
            }
        }

        guard !unprojectedWriters.isEmpty else { return false }
        return rollouts.active(now: now, boot: boot, writers: unprojectedWriters)
    }

    private func openHistory() -> TurnHistory? {
        var info = stat()
        guard lstat(historyURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            history = nil
            return nil
        }
        if history?.inode != info.st_ino || history?.device != info.st_dev {
            history = TurnHistory(url: historyURL, inode: info.st_ino, device: info.st_dev)
        }
        return history
    }

    private func writerLocks() -> [String: Date]? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: locksURL.path) else { return nil }
        var live: [String: Date] = [:]
        for name in files where name.hasSuffix(".lock") {
            let id = String(name.dropLast(5))
            guard UUID(uuidString: id) != nil else { continue }
            let path = locksURL.appendingPathComponent(name).path
            let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }

            if flock(fd, LOCK_SH | LOCK_NB) != 0, errno == EWOULDBLOCK {
                let created = TimeInterval(info.st_birthtimespec.tv_sec)
                    + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000
                live[id.lowercased()] = Date(timeIntervalSince1970: created)
            }
        }
        return live
    }
}

private final class TurnHistory {
    enum Turn {
        case started(Date)
        case ended
        case unavailable
    }

    let inode: ino_t
    let device: dev_t
    private let database: OpaquePointer
    private let latest: OpaquePointer

    init?(url: URL, inode: ino_t, device: dev_t) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_busy_timeout(database, 40)

        // The thread/ordinal index makes this a bounded lookup for each live writer.
        let sql = """
            SELECT status, started_at FROM thread_turns
            WHERE thread_id = ?1 ORDER BY rollout_ordinal DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            sqlite3_close(database)
            return nil
        }

        self.inode = inode
        self.device = device
        self.database = database
        latest = statement
    }

    func latestTurn(threadID: String) -> Turn {
        sqlite3_reset(latest)
        defer { sqlite3_reset(latest) }
        let result = threadID.withCString { id in
            sqlite3_bind_text(latest, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK, sqlite3_step(latest) == SQLITE_ROW,
              let value = sqlite3_column_text(latest, 0) else { return .unavailable }

        switch String(cString: value) {
        case "inProgress":
            guard sqlite3_column_type(latest, 1) == SQLITE_INTEGER else { return .unavailable }
            let posted = TimeInterval(sqlite3_column_int64(latest, 1))
            return .started(Date(timeIntervalSince1970: posted))
        case "completed", "failed", "interrupted":
            return .ended
        default:
            return .unavailable
        }
    }

    deinit {
        sqlite3_finalize(latest)
        sqlite3_close(database)
    }
}

private final class RecentRollouts {
    enum Marker {
        case start(Date)
        case end
    }

    struct Candidate {
        let url: URL
        let id: String
        let modified: Date
        let byteCount: Int
    }

    struct CacheEntry {
        let modified: Date
        let byteCount: Int
        let marker: Marker?
    }

    private let root: URL
    private let format = ISO8601DateFormatter()
    private let wholeSecondsFormat = ISO8601DateFormatter()
    private let record = try! NSRegularExpression(pattern: #"^\s*\{\s*"timestamp"\s*:\s*"([^"]+)"\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"event_msg"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"(task_started|task_complete|turn_aborted|task_failed)"\s*[,}]"#)
    private var cache: [URL: CacheEntry] = [:]

    init(root: URL) {
        self.root = root
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func active(now: Date, boot: Date, writers: [String: Date]?) -> Bool {
        let oldest = now.addingTimeInterval(writers == nil ? -5 * 60 : -30 * 60)
        let candidates = recentFiles(now: now, oldest: oldest, writers: writers)
        let urls = Set(candidates.map(\.url))
        cache = cache.filter { urls.contains($0.key) }
        for candidate in candidates {
            let entry = cache[candidate.url]
            let marker: Marker?
            if let entry, entry.modified == candidate.modified, entry.byteCount == candidate.byteCount {
                marker = entry.marker
            } else {
                // A substantial append can move the start out of the tail. Keep a
                // previously complete marker until a newer complete marker arrives.
                let olderMarker = (entry?.byteCount ?? 0) <= candidate.byteCount ? entry?.marker : nil
                marker = latestMarker(in: candidate) ?? olderMarker
                cache[candidate.url] = CacheEntry(modified: candidate.modified, byteCount: candidate.byteCount, marker: marker)
            }

            guard case let .start(started) = marker else { continue }
            let timeFloor = max(boot, oldest, writers?[candidate.id] ?? .distantPast)
            if started >= timeFloor.addingTimeInterval(-3), started <= now.addingTimeInterval(3) {
                return true
            }
        }
        return false
    }

    private func recentFiles(now: Date, oldest: Date, writers: [String: Date]?) -> [Candidate] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now) ?? now]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var files: [Candidate] = []
        for day in days {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let datePath = String(format: "%04d/%02d/%02d", year, month, day)
            let dateURL = root.appendingPathComponent(datePath, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(at: dateURL, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
            for url in urls where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                let id = String(url.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
                guard UUID(uuidString: id) != nil, writers == nil || writers?[id] != nil,
                      let attrs = try? url.resourceValues(forKeys: keys),
                      attrs.isRegularFile == true, attrs.isSymbolicLink == false,
                      let modified = attrs.contentModificationDate, modified >= oldest,
                      let byteCount = attrs.fileSize, byteCount > 0 else { continue }
                files.append(Candidate(url: url, id: id, modified: modified, byteCount: byteCount))
            }
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(12))
    }

    private func latestMarker(in candidate: Candidate) -> Marker? {
        guard let file = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? file.close() }
        let maxBytes = 512 * 1024
        let offset = max(candidate.byteCount - maxBytes, 0)
        guard (try? file.seek(toOffset: UInt64(offset))) != nil,
              let data = try? file.read(upToCount: maxBytes),
              let end = data.lastIndex(of: 10) else { return nil }

        var start = data.startIndex
        if offset > 0 {
            // Only interpret a full JSONL line when starting in the file's middle.
            guard let firstBreak = data.firstIndex(of: 10), firstBreak < end else { return nil }
            start = data.index(after: firstBreak)
        }
        for line in data[start..<end].split(separator: 10).reversed() {
            let prefix = String(decoding: line.prefix(256), as: UTF8.self)
            guard let match = record.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
                  let type = Range(match.range(at: 2), in: prefix) else { continue }
            if prefix[type] != "task_started" { return .end }
            guard let range = Range(match.range(at: 1), in: prefix) else { continue }
            let stamp = String(prefix[range])
            if let date = format.date(from: stamp) ?? wholeSecondsFormat.date(from: stamp) {
                return .start(date)
            }
        }
        return nil
    }
}
