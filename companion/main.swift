import AppKit
import Darwin
import Foundation
import SwiftUI

private let hubIdentity = "com.local.desktop-pet-studio"
private let commandName = Notification.Name(hubIdentity + ".command")

enum DragonArtwork {
    static let states: [(String, Int)] = [("dance", 8), ("idle", 6), ("jumping", 5), ("running", 6),
        ("running-left", 8), ("running-right", 8), ("waiting", 6), ("waving", 4)]
    static var files: [String] {
        states.flatMap { state, count in (0..<count).map { "Frames/\(state)/" + String(format: "%02d.png", $0) } }
    }
    static func isValid(_ directory: URL) -> Bool {
        files.allSatisfy { name in
            let file = directory.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes > 0, bytes < 8_000_000,
                  let data = try? Data(contentsOf: file),
                  let image = NSBitmapImageRep(data: data) else { return false }
            return (image.pixelsWide == 288 && image.pixelsHigh == 312) ||
                   (image.pixelsWide == 192 && image.pixelsHigh == 208)
        }
    }
    static func install(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink != true,
              !fm.fileExists(atPath: destination.path) || values?.isDirectory == true else {
            throw failure("白龙素材目录无法使用，原有内容已保留。")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".dragon-import-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        for name in files {
            let target = stage.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Re-encode image pixels to omit metadata and exclude every unrelated source file.
            guard let data = try? Data(contentsOf: source.appendingPathComponent(name)),
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw failure("白龙素材无法读取，原有内容已保留。")
            }
            try png.write(to: target)
        }
        guard isValid(stage) else { throw failure("白龙素材不完整，原有内容已保留。") }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stage, backupItemName: nil, options: [])
        } else { try fm.moveItem(at: stage, to: destination) }
    }
}

enum PetKind: String, Codable, CaseIterable {
    case dragon, whale
    var name: String { self == .dragon ? "GPT 白龙" : "DeepSeek 大肥鱼" }
    var shortName: String { self == .dragon ? "白龙" : "大肥鱼" }
    var bundleName: String { self == .dragon ? "GPT白龙.app" : "DeepSeek大肥鱼.app" }
    var executable: String { self == .dragon ? "GPTDragon" : "DeepSeekWhale" }
    var preview: String { self == .dragon ? "Dragon.png" : "Whale.png" }
    var slot: Int { self == .dragon ? 0 : 1 }
    var detail: String { self == .dragon ? "打招呼 · 跳舞 · 散步" : "甩尾巴 · 撒娇 · 吃饭" }
    var color: Color {
        self == .dragon ? Color(red: 0.75, green: 0.37, blue: 0.53) : Color(red: 0.22, green: 0.43, blue: 0.77)
    }
}

struct PetSpec: Codable, Identifiable {
    let id: UUID
    let kind: PetKind
    let slot: Int
    var title: String { kind.name }
}

struct HubPreferences: Codable {
    var restoreOnLaunch = true
    var socialEnabled = true
    var pets: [PetSpec] = []
    var widths: [String: Int] = [:]
    enum CodingKeys: String, CodingKey { case restoreOnLaunch, socialEnabled, pets, widths }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restoreOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch) ?? true
        socialEnabled = try values.decodeIfPresent(Bool.self, forKey: .socialEnabled) ?? true
        pets = try values.decodeIfPresent([PetSpec].self, forKey: .pets) ?? []
        widths = try values.decodeIfPresent([String: Int].self, forKey: .widths) ?? [:]
        widths = widths.filter { PetKind(rawValue: $0.key) != nil && (80...224).contains($0.value) }
    }
}

struct HubDisk {
    let directory: URL
    init() throws {
        if let path = ProcessInfo.processInfo.environment["DESKTOP_PET_HUB_DATA_DIR"] {
            guard path.hasPrefix("/") else { throw failure("应用数据目录无效。") }
            directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DesktopPetStudio", isDirectory: true)
        }
    }
    var status: URL { directory.appendingPathComponent("status.json") }
    var preferences: URL { directory.appendingPathComponent("preferences.json") }
    func reply(_ request: String) -> URL {
        directory.appendingPathComponent("Replies", isDirectory: true).appendingPathComponent(request + ".json")
    }
    func instance(_ id: UUID) -> URL {
        directory.appendingPathComponent("Instances", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    func claim() throws -> Int32? {
        try prepare()
        let fd = open(directory.appendingPathComponent("manager.lock").path,
                      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("无法打开桌宠伙伴。") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let reason = errno
        close(fd)
        if reason == EWOULDBLOCK { return nil }
        throw failure("无法锁定桌宠伙伴。")
    }
    var isRunning: Bool {
        let fd = open(directory.appendingPathComponent("manager.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) == -1 && errno == EWOULDBLOCK
    }
    func snapshot() -> [String: Any] {
        guard let data = try? Data(contentsOf: status),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    func send(_ action: String, value: String? = nil, count: Int = 1) -> [String: Any]? {
        guard isRunning else { return nil }
        let request = UUID().uuidString
        var command: [String: Any] = ["action": action, "request": request, "count": count]
        command["value"] = value
        DistributedNotificationCenter.default().postNotificationName(
            commandName, object: directory.path, userInfo: command, deliverImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: reply(request)),
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(at: reply(request))
                return report
            }
            Thread.sleep(forTimeInterval: 0.035)
        }
        return nil
    }
}

private func failure(_ message: String) -> NSError {
    NSError(domain: hubIdentity, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct ActivePet: Identifiable {
    let spec: PetSpec
    let process: Process
    let environment: [String: String]
    var report: [String: Any] = [:]
    var stopping = false
    var id: UUID { spec.id }
    var description: String {
        if stopping { return "正在收回" }
        guard !report.isEmpty else { return "正在召唤" }
        if report["visible"] as? Bool == false { return "已隐藏" }
        if report["working"] as? Bool == true { return "正在陪你工作" }
        return "在桌面陪着你"
    }
}

final class HubStore: ObservableObject {
    @Published var pets: [ActivePet] = []
    @Published var restoreOnLaunch: Bool {
        didSet { preferences.restoreOnLaunch = restoreOnLaunch; savePreferences() }
    }
    @Published var socialEnabled: Bool {
        didSet {
            preferences.socialEnabled = socialEnabled
            savePreferences()
            if !socialEnabled { cancelInteraction() }
        }
    }
    @Published private(set) var interactionTitle: String?
    @Published var errorMessage: String?
    @Published private(set) var restoring = false
    @Published private(set) var customWidths: [String: Int] = [:]
    let disk: HubDisk
    private var preferences: HubPreferences
    private var timer: Timer?
    private var closing = false
    private var lastCommand: [String: Any]?
    private var restoreGeneration = 0
    private var dismissalCompletions: [UUID: [() -> Void]] = [:]
    private var childQueues: [UUID: DispatchQueue] = [:]
    private var sizeGenerations: [PetKind: Int] = [:]
    private var pendingSizes: Set<PetKind> = []
    private var pruneCounter = 0
    private var settingsReadable = true
    private struct PairSession {
        let plan: PairInteractionPlan
        let petIDs: [UUID]
        var acknowledged = false
        var accepted: Set<UUID> = []
    }
    private var pairSession: PairSession?
    private var interactionTimer: Timer?
    private var interactionCompleted = 0
    private var interactionCancelled = 0
    private var nextAutomaticInteraction = ProcessInfo.processInfo.systemUptime + 18
    private var nearInteractionIndex = 0
    private var farInteractionIndex = 0
    private var initiatorIndex = 0
    private let controls = DispatchQueue(label: hubIdentity + ".controls", attributes: .concurrent)
    var onReveal: (() -> Void)?

    init(disk: HubDisk) {
        self.disk = disk
        let bytes = try? Data(contentsOf: disk.preferences)
        let decoded = bytes.flatMap { try? JSONDecoder().decode(HubPreferences.self, from: $0) }
        let preserveUnreadable = FileManager.default.fileExists(atPath: disk.preferences.path) && decoded == nil
        var loaded = decoded ?? HubPreferences()
        var seen: Set<PetKind> = []
        loaded.pets = loaded.pets.filter { seen.insert($0.kind).inserted }
            .map { PetSpec(id: $0.id, kind: $0.kind, slot: $0.kind.slot) }
        if let bytes, let old = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           old["widths"] == nil {
            // Adopt an existing standalone-per-instance size only once during the upgrade.
            for spec in loaded.pets {
                let path = disk.instance(spec.id).appendingPathComponent(
                    spec.kind == .dragon ? "preferences.plist" : "preferences.json")
                if let data = try? Data(contentsOf: path) {
                    let values: [String: Any]?
                    if spec.kind == .dragon {
                        values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                    } else { values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
                    if let width = values?["independentWidth"] as? Int, (80...224).contains(width) {
                        loaded.widths[spec.kind.rawValue] = width
                    }
                }
            }
        }
        preferences = loaded
        customWidths = loaded.widths
        restoreOnLaunch = preferences.restoreOnLaunch
        socialEnabled = preferences.socialEnabled
        settingsReadable = !preserveUnreadable
        if preserveUnreadable { errorMessage = "设置暂时无法读取，原有设置和伙伴数据已保留。" }
    }

    func start() {
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if restoreOnLaunch && !preferences.pets.isEmpty {
            let saved = preferences.pets
            restoring = true
            restoreGeneration += 1
            let generation = restoreGeneration
            let disk = self.disk
            controls.async { [weak self] in
                // After a forced close, workers need at most one maintenance interval to exit.
                let deadline = ProcessInfo.processInfo.systemUptime + 7
                var occupied = saved.filter { Self.lockHeld(at: disk.instance($0.id)) }
                while !occupied.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.06)
                    occupied = saved.filter { Self.lockHeld(at: disk.instance($0.id)) }
                }
                let blocked = Set(occupied.map(\.id))
                DispatchQueue.main.async {
                    guard let self, !self.closing, self.restoreGeneration == generation else { return }
                    self.restoring = false
                    for spec in saved where !blocked.contains(spec.id) {
                        do { try self.spawn(spec, restoring: true) }
                        catch { self.errorMessage = error.localizedDescription }
                    }
                    if !blocked.isEmpty {
                        self.preferences.pets.removeAll { blocked.contains($0.id) }
                        self.savePreferences()
                        self.errorMessage = "部分伙伴还在收尾，稍后可以重新召唤。"
                    }
                    self.writeStatus()
                    self.pruneRetiredInstances()
                }
            }
        } else if !restoreOnLaunch {
            preferences.pets = []
            savePreferences()
        }
        pruneRetiredInstances()
        writeStatus()
    }
    private static func lockHeld(at directory: URL) -> Bool {
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) == -1 && errno == EWOULDBLOCK
    }

    @Published var artworkRevision = 0
    private var artworkChecked = false
    private var artworkCache: URL?
    var dragonArtwork: URL? {
        if artworkChecked { return artworkCache }
        artworkChecked = true
        let env = ProcessInfo.processInfo.environment["DESKTOP_PET_DRAGON_ARTWORK_DIR"]
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Engines/GPT白龙.app/Contents/Resources")
        let candidates = [env.map { URL(fileURLWithPath: $0, isDirectory: true) },
                          disk.directory.appendingPathComponent("DragonArtwork"), bundled].compactMap { $0 }
        artworkCache = candidates.first { DragonArtwork.isValid($0) }
        return artworkCache
    }
    func importDragonArtwork() {
        guard !isSummoned(.dragon), !closing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择你有权使用的白龙应用或素材文件夹。素材只会保存在这台电脑。"
        panel.prompt = "导入素材"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let candidates = [chosen,
                chosen.appendingPathComponent("Contents/Resources"),
                chosen.appendingPathComponent("Contents/Resources/Engines/GPT白龙.app/Contents/Resources")]
            guard let source = candidates.first(where: { DragonArtwork.isValid($0) }) else {
                throw failure("没有找到完整的白龙动画，请选择原有白龙应用或包含 Frames 的素材目录。")
            }
            try DragonArtwork.install(source, to: disk.directory.appendingPathComponent("DragonArtwork"))
            artworkChecked = false
            artworkRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }
    func summon(_ kind: PetKind) {
        do { try summonChecked(kind) } catch { errorMessage = error.localizedDescription }
    }
    func isSummoned(_ kind: PetKind) -> Bool { pets.contains { $0.spec.kind == kind } }
    func summonTogether() {
        for kind in PetKind.allCases where !isSummoned(kind) { summon(kind) }
    }
    func width(for kind: PetKind) -> Int {
        customWidths[kind.rawValue] ?? NativePetSizeReader().width()
    }
    func setSize(_ kind: PetKind, width: Int?) {
        guard !closing, width == nil || (80...224).contains(width!) else { return }
        customWidths[kind.rawValue] = width
        savePreferences()
        sizeGenerations[kind, default: 0] += 1
        let generation = sizeGenerations[kind]!
        guard let pet = pets.first(where: { $0.spec.kind == kind && !$0.stopping }) else { return }
        pendingSizes.insert(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.applySize(kind, id: pet.id, width: width, generation: generation, attempts: 0)
        }
    }
    private func applySize(_ kind: PetKind, id: UUID, width: Int?, generation: Int, attempts: Int) {
        guard !closing, sizeGenerations[kind] == generation,
              let pet = pets.first(where: { $0.id == id && !$0.stopping }) else { return }
        if pet.report.isEmpty {
            guard attempts < 30 else {
                pendingSizes.remove(kind)
                errorMessage = "伙伴还在准备，稍后可以重新调整大小。"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.applySize(kind, id: id, width: width, generation: generation, attempts: attempts + 1)
            }
            return
        }
        controlQueue(id).async { [weak self] in
            let ok = self?.command(pet, "--size", argument: width.map(String.init) ?? "follow") ?? false
            DispatchQueue.main.async {
                guard let self, self.sizeGenerations[kind] == generation else { return }
                if ok { self.pendingSizes.remove(kind); self.refresh() }
                else {
                    self.pendingSizes.remove(kind)
                    self.errorMessage = "大小没有调整成功，请稍后重试。"
                }
            }
        }
    }
    private func summonChecked(_ kind: PetKind) throws {
        guard !closing else { throw failure("应用正在退出。") }
        guard !restoring else { throw failure("正在恢复伙伴，请稍等一会儿。") }
        if let current = pets.first(where: { $0.spec.kind == kind }) {
            guard !current.stopping else { throw failure("这位伙伴正在收回，请稍后再召唤。") }
            reveal(current.id)
            return
        }
        let spec = PetSpec(id: UUID(), kind: kind, slot: kind.slot)
        try spawn(spec, restoring: false)
    }
    private func binary(_ kind: PetKind) throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw failure("无法读取桌宠资源。") }
        let path = resources.appendingPathComponent("Engines/\(kind.bundleName)/Contents/MacOS/\(kind.executable)")
        guard FileManager.default.isExecutableFile(atPath: path.path) else { throw failure("\(kind.name)的资源不完整，请重新安装应用。") }
        return path
    }
    private func spawn(_ spec: PetSpec, restoring: Bool) throws {
        guard !pets.contains(where: { $0.spec.kind == spec.kind }) else { return }
        if spec.kind == .dragon && dragonArtwork == nil {
            throw failure("请先在白龙卡片中导入你有权使用的白龙素材。")
        }
        let executable = try binary(spec.kind)
        let dir = disk.instance(spec.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let environment = ProcessInfo.processInfo.environment
        let quiet = environment["DESKTOP_PET_HUB_QUIET"] == "1"
        let audioPlaybackTest = quiet && environment["DESKTOP_PET_AUDIO_TEST_SILENT"] == "1" &&
            environment["DESKTOP_PET_ACTIVITY_TEST_HOME"] != nil
        let muted = quiet && !audioPlaybackTest
        let screen = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 18, dy: 18)
        let width = CGFloat(self.width(for: spec.kind))
        let height = width * 208 / 192
        let origin = NSPoint(
            x: screen.maxX - width - CGFloat(spec.slot % 4) * max(0, screen.width - width) / 3,
            y: screen.minY + CGFloat(spec.slot / 4) * max(0, screen.height - height) / 2)
        if spec.kind == .whale {
            let path = dir.appendingPathComponent("preferences.json")
            var prefs = ((try? Data(contentsOf: path)).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }) ?? ["hidden": false, "roaming": true, "muted": muted,
                                       "completionVoice": false, "skin": "figurine",
                                       "position": ["x": origin.x + width / 2, "y": origin.y + height / 2]]
            prefs["independentWidth"] = customWidths[spec.kind.rawValue]
            try JSONSerialization.data(withJSONObject: prefs).write(to: path, options: .atomic)
        }
        if spec.kind == .dragon {
            let path = dir.appendingPathComponent("preferences.plist")
            var values = ((try? Data(contentsOf: path)).flatMap {
                (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
            }) ?? ["muted": muted]
            values["independentWidth"] = customWidths[spec.kind.rawValue]
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                .write(to: path, options: .atomic)
        }
        if spec.kind == .dragon && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("status.json").path) {
            try JSONSerialization.data(withJSONObject: ["position": ["x": origin.x, "y": origin.y]])
                .write(to: dir.appendingPathComponent("status.json"), options: .atomic)
        }
        var env = ProcessInfo.processInfo.environment
        // Managed workers always use their own state, never the standalone or UI-test state.
        env.removeValue(forKey: "WHALE_PET_UI_TEST")
        env.removeValue(forKey: "WHALE_PET_DATA_DIR")
        if spec.kind == .dragon { env["DESKTOP_PET_DRAGON_ARTWORK_DIR"] = dragonArtwork?.path }
        env["DESKTOP_PET_MANAGED"] = "1"
        env["DESKTOP_PET_INSTANCE_ID"] = spec.id.uuidString
        env["DESKTOP_PET_INSTANCE_DIR"] = dir.path
        env["DESKTOP_PET_SPAWN_SLOT"] = String(spec.slot)
        env["DESKTOP_PET_MANAGER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = executable
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        let log = dir.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        process.standardError = try FileHandle(forWritingTo: log)
        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { self?.finished(spec.id, code: child.terminationStatus) }
        }
        try process.run()
        pets.append(ActivePet(spec: spec, process: process, environment: env))
        if !restoring { preferences.pets.append(spec) }
        savePreferences()
        writeStatus()
    }

    func reveal(_ id: UUID) {
        guard let pet = pets.first(where: { $0.id == id }), !pet.stopping else { return }
        controlQueue(id).async { [weak self] in _ = self?.command(pet, "--show") }
    }
    func dismiss(_ id: UUID, completion: (() -> Void)? = nil) {
        guard let index = pets.firstIndex(where: { $0.id == id }) else { completion?(); return }
        if let completion { dismissalCompletions[id, default: []].append(completion) }
        if pets[index].stopping { return }
        pets[index].stopping = true
        let pet = pets[index]
        if pairSession?.petIDs.contains(id) == true { cancelInteraction() }
        sizeGenerations[pet.spec.kind, default: 0] += 1
        pendingSizes.remove(pet.spec.kind)
        if !closing { preferences.pets.removeAll { $0.id == id }; savePreferences() }
        controlQueue(id).async { [weak self] in
            _ = self?.command(pet, "--quit")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while pet.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.04)
            }
            if pet.process.isRunning { pet.process.terminate() }
            let finalDeadline = ProcessInfo.processInfo.systemUptime + 2
            while pet.process.isRunning && ProcessInfo.processInfo.systemUptime < finalDeadline {
                Thread.sleep(forTimeInterval: 0.035)
            }
            if pet.process.isRunning { kill(pet.process.processIdentifier, SIGKILL) }
            pet.process.waitUntilExit()
            DispatchQueue.main.async { [weak self] in self?.finished(id, code: pet.process.terminationStatus) }
        }
        writeStatus()
    }
    func interact(_ behavior: SocialBehavior) {
        do { try beginInteraction(behavior) }
        catch { errorMessage = error.localizedDescription }
    }
    private func socialFrame(_ pet: ActivePet) -> NSRect? {
        guard let position = pet.report["position"] as? [String: Any],
              let x = position["x"] as? Double, let y = position["y"] as? Double,
              let width = pet.report["petWidth"] as? Double,
              [x, y, width].allSatisfy(\.isFinite), (80...224).contains(width) else { return nil }
        let size = pet.report["size"] as? [String: Any]
        let height = (size?["height"] as? Double) ?? width * 208 / 192
        guard height.isFinite, height > 0, height < 400 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
    private func socialPair() throws -> ([ActivePet], [NSRect], NSScreen) {
        guard !closing, !restoring, pets.count == 2,
              let dragon = pets.first(where: { $0.spec.kind == .dragon }),
              let whale = pets.first(where: { $0.spec.kind == .whale }) else {
            throw failure("先召唤白龙和大肥鱼，再一起玩吧。")
        }
        let pair = [dragon, whale]
        guard pendingSizes.isEmpty,
              pair.allSatisfy({ !$0.stopping && $0.process.isRunning && $0.report["interactionReady"] as? Bool == true }) else {
            throw failure("伙伴正在忙或播放动作，等一小会儿再一起玩吧。")
        }
        let frames = pair.compactMap(socialFrame)
        guard frames.count == 2, let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(NSPoint(x: frames[0].midX, y: frames[0].midY)) &&
            $0.visibleFrame.contains(NSPoint(x: frames[1].midX, y: frames[1].midY))
        }) else { throw failure("把两位伙伴放到同一块屏幕上，再一起玩吧。") }
        return (pair, frames, screen)
    }
    private func beginInteraction(_ behavior: SocialBehavior, initiator requested: PetKind? = nil) throws {
        guard pairSession == nil else { throw failure("伙伴们正在一起玩，稍后再换一个动作。") }
        let (pair, frames, screen) = try socialPair()
        var leader = requested.map { $0 == .dragon ? 0 : 1 } ?? initiatorIndex % 2
        if behavior == .chase && requested == nil {
            let firstIsRight = frames[0].midX >= frames[1].midX
            let firstSpace = firstIsRight ? screen.visibleFrame.maxX - frames[0].maxX : frames[0].minX - screen.visibleFrame.minX
            let secondSpace = firstIsRight ? frames[1].minX - screen.visibleFrame.minX : screen.visibleFrame.maxX - frames[1].maxX
            leader = firstSpace >= secondSpace ? 0 : 1
        }
        var plan = PairInteractionPlan(behavior: behavior, first: frames[0], second: frames[1],
                                       screen: screen.visibleFrame.insetBy(dx: 8, dy: 8),
                                       initiator: leader)
        guard let resources = Bundle.main.resourceURL else { throw failure("无法读取互动台词。") }
        try plan.addDialogue(resources: resources)
        let payloads = try [plan.payload(for: 0), plan.payload(for: 1)]
        try writeDialoguePermit(plan.id, phase: "preparing", participants: pair)
        pairSession = PairSession(plan: plan, petIDs: pair.map(\.id))
        interactionTitle = behavior.title
        initiatorIndex += 1
        nextAutomaticInteraction = plan.startAt + plan.duration + 25
        let heartbeat = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.checkDialogueParticipants() }
        RunLoop.main.add(heartbeat, forMode: .common)
        interactionTimer = heartbeat
        for (index, pet) in pair.enumerated() {
            controlQueue(pet.id).async { [weak self] in
                let ok = self?.command(pet, "--interact", argument: payloads[index]) ?? false
                DispatchQueue.main.async {
                    guard let self, self.pairSession?.plan.id == plan.id else { return }
                    if !ok { self.cancelInteraction(); return }
                    self.pairSession?.accepted.insert(pet.id)
                    if self.pairSession?.accepted.count == 2 {
                        guard ProcessInfo.processInfo.systemUptime < plan.startAt - 0.1 else {
                            self.cancelInteraction(); return
                        }
                        do {
                            try self.writeDialoguePermit(plan.id, phase: "committed", participants: pair)
                            self.pairSession?.acknowledged = true
                        } catch { self.cancelInteraction() }
                    }
                }
            }
        }
        writeStatus()
    }
    func cancelInteraction() {
        guard let session = pairSession else { return }
        clearDialoguePermit()
        pairSession = nil
        interactionTitle = nil
        interactionCancelled += 1
        nextAutomaticInteraction = ProcessInfo.processInfo.systemUptime + 25
        for pet in pets where session.petIDs.contains(pet.id) && pet.process.isRunning {
            controlQueue(pet.id).async { [weak self] in
                _ = self?.command(pet, "--cancel-interaction", argument: session.plan.id.uuidString)
            }
        }
        writeStatus()
    }
    private var dialoguePermitURL: URL { disk.directory.appendingPathComponent("dialogue-session.json") }
    private func writeDialoguePermit(_ id: UUID, phase: String, participants: [ActivePet]) throws {
        if let values = try? dialoguePermitURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw failure("互动同步文件无法使用，请重新打开桌宠伙伴。")
        }
        let report: [String: Any] = ["owner": hubIdentity, "id": id.uuidString, "phase": phase,
            "participants": participants.map { ["kind": $0.spec.kind.rawValue, "id": $0.id.uuidString,
                                               "pid": Int($0.process.processIdentifier)] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: report).write(to: dialoguePermitURL, options: .atomic)
    }
    private func clearDialoguePermit() {
        interactionTimer?.invalidate()
        interactionTimer = nil
        guard let values = try? dialoguePermitURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: dialoguePermitURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["owner"] as? String == hubIdentity else { return }
        try? FileManager.default.removeItem(at: dialoguePermitURL)
    }
    private func checkDialogueParticipants() {
        guard let session = pairSession else { clearDialoguePermit(); return }
        if !session.acknowledged {
            if ProcessInfo.processInfo.systemUptime >= session.plan.startAt - 0.1 { cancelInteraction() }
            return
        }
        for id in session.petIDs {
            guard let pet = pets.first(where: { $0.id == id }), !pet.stopping, pet.process.isRunning,
                  let data = try? Data(contentsOf: disk.instance(id).appendingPathComponent("status.json")),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (status["instanceID"] as? String)?.lowercased() == id.uuidString.lowercased(),
                  status["pid"] as? Int == Int(pet.process.processIdentifier) else {
                cancelInteraction(); return
            }
            let active = status["interaction"] as? [String: Any]
            let last = status["lastInteraction"] as? [String: Any]
            let isCurrent = (active?["id"] as? String)?.lowercased() == session.plan.id.uuidString.lowercased()
            let finished = (last?["id"] as? String)?.lowercased() == session.plan.id.uuidString.lowercased() &&
                last?["phase"] as? String == "completed"
            if !isCurrent && !finished { cancelInteraction(); return }
            if let dialogue = status["lastDialogue"] as? [String: Any],
               (dialogue["id"] as? String)?.lowercased() == session.plan.id.uuidString.lowercased(),
               ["cancelled", "failed"].contains(dialogue["phase"] as? String ?? "") { cancelInteraction(); return }
        }
    }
    private func refreshInteractions() {
        let now = ProcessInfo.processInfo.systemUptime
        if let session = pairSession {
            let current = pets.filter { session.petIDs.contains($0.id) }
            if current.count != 2 || current.contains(where: { $0.stopping || !$0.process.isRunning }) {
                cancelInteraction(); return
            }
            let records = current.compactMap { $0.report["lastInteraction"] as? [String: Any] }
            let matching = records.filter { ($0["id"] as? String)?.lowercased() == session.plan.id.uuidString.lowercased() }
            let dialogues = current.compactMap { $0.report["lastDialogue"] as? [String: Any] }
            if dialogues.contains(where: {
                ($0["id"] as? String)?.lowercased() == session.plan.id.uuidString.lowercased() &&
                    ["cancelled", "failed"].contains($0["phase"] as? String ?? "")
            }) { cancelInteraction(); return }
            if matching.contains(where: { $0["phase"] as? String == "cancelled" }) {
                cancelInteraction(); return
            }
            if matching.count == 2 && matching.allSatisfy({ $0["phase"] as? String == "completed" }) {
                clearDialoguePermit()
                pairSession = nil
                interactionTitle = nil
                interactionCompleted += 1
                nextAutomaticInteraction = now + Double.random(in: 25...40)
            } else if pairSession?.acknowledged != true && now > session.plan.startAt - 0.1 {
                cancelInteraction()
            } else if now > session.plan.startAt + session.plan.duration + 4 {
                cancelInteraction()
            }
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let automaticAllowed = environment["DESKTOP_PET_HUB_QUIET"] != "1" ||
            (environment["DESKTOP_PET_SOCIAL_AUTOPLAY_TEST"] == "1" && environment["DESKTOP_PET_ACTIVITY_TEST_HOME"] != nil)
        guard socialEnabled, !closing, !restoring, automaticAllowed,
              now >= nextAutomaticInteraction,
              let (_, frames, _) = try? socialPair() else { return }
        let near = PairInteractionPlan.gap(frames[0], frames[1]) <= 110
        let choices = SocialBehavior.allCases.filter { $0.shortDistance == near }
        let index = near ? nearInteractionIndex : farInteractionIndex
        if near { nearInteractionIndex += 1 } else { farInteractionIndex += 1 }
        try? beginInteraction(choices[index % choices.count])
    }
    private func controlQueue(_ id: UUID) -> DispatchQueue {
        if let queue = childQueues[id] { return queue }
        let queue = DispatchQueue(label: hubIdentity + ".worker." + id.uuidString)
        childQueues[id] = queue
        return queue
    }
    private func command(_ pet: ActivePet, _ action: String, argument: String? = nil) -> Bool {
        guard pet.process.isRunning else { return false }
        let client = Process()
        client.executableURL = pet.process.executableURL
        client.environment = pet.environment
        client.arguments = [action] + (argument.map { [$0] } ?? [])
        let output = Pipe()
        client.standardOutput = output
        client.standardError = FileHandle.nullDevice
        do {
            try client.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            client.waitUntilExit()
            guard client.terminationStatus == 0 else { return false }
            if action == "--interact" {
                guard let argument, let requestBytes = argument.data(using: .utf8),
                      let request = try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any],
                      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let active = response["interaction"] as? [String: Any],
                      let id = request["id"] as? String,
                      (active["id"] as? String)?.lowercased() == id.lowercased() else { return false }
            }
            return true
        }
        catch { NSLog("Pet control: %@", error.localizedDescription); return false }
    }
    func dismissAll(completion: (() -> Void)? = nil) {
        if !closing {
            restoreGeneration += 1
            restoring = false
            preferences.pets = []
            savePreferences()
        }
        let ids = pets.map(\.id)
        guard !ids.isEmpty else { completion?(); return }
        let group = DispatchGroup()
        for id in ids { group.enter(); dismiss(id) { group.leave() } }
        group.notify(queue: .main) { completion?() }
    }
    func shutdown(completion: @escaping () -> Void) {
        closing = true
        restoreGeneration += 1
        restoring = false
        timer?.invalidate()
        // Keep the chosen roster for a normal reopening, but stop every child now.
        savePreferences()
        dismissAll { DispatchQueue.main.async { completion() } }
    }
    func stopForApplicationExit() {
        // AppKit may suspend main-dispatch callbacks while waiting for terminateLater.
        // Deliver each worker's existing scoped quit command directly, then wait on OS liveness.
        closing = true
        if pairSession != nil { interactionCancelled += 1 }
        clearDialoguePermit()
        pairSession = nil
        interactionTitle = nil
        restoreGeneration += 1
        restoring = false
        timer?.invalidate()
        savePreferences()
        let current = pets
        for pet in current where pet.process.isRunning {
            let event: Notification.Name
            let object: String?
            let payload: [String: Any]
            if pet.spec.kind == .dragon {
                event = .init("com.local.desktop-pet-manager.engine.\(pet.id.uuidString.lowercased()).dismiss")
                object = nil
                payload = ["requestID": UUID().uuidString]
            } else {
                event = .init("com.local.deepseek.whalepet.command")
                object = disk.instance(pet.id).path
                payload = ["command": "quit", "request": UUID().uuidString]
            }
            DistributedNotificationCenter.default().postNotificationName(
                event, object: object, userInfo: payload, deliverImmediately: true)
        }
        func live(_ pet: ActivePet) -> Bool {
            kill(pet.process.processIdentifier, 0) == 0
        }
        let graceful = ProcessInfo.processInfo.systemUptime + 2.5
        while current.contains(where: live) && ProcessInfo.processInfo.systemUptime < graceful {
            Thread.sleep(forTimeInterval: 0.025)
        }
        for pet in current where live(pet) && pet.process.isRunning { pet.process.terminate() }
        let fallback = ProcessInfo.processInfo.systemUptime + 1
        while current.contains(where: live) && ProcessInfo.processInfo.systemUptime < fallback {
            Thread.sleep(forTimeInterval: 0.025)
        }
        for pet in current where live(pet) && pet.process.isRunning {
            kill(pet.process.processIdentifier, SIGKILL)
        }
        pets = []
        writeStatus()
    }
    private func finished(_ id: UUID, code: Int32) {
        if pairSession?.petIDs.contains(id) == true { cancelInteraction() }
        guard let pet = pets.first(where: { $0.id == id }) else { return }
        if !closing {
            preferences.pets.removeAll { $0.id == id }
            if !pet.stopping && code != 0 { errorMessage = "\(pet.spec.kind.name)没有成功留在桌面，请重新召唤。" }
        }
        pets.removeAll { $0.id == id }
        childQueues.removeValue(forKey: id)
        pendingSizes.remove(pet.spec.kind)
        if !closing { removeInstanceData(id) }
        savePreferences()
        writeStatus()
        let callbacks = dismissalCompletions.removeValue(forKey: id) ?? []
        for callback in callbacks { callback() }
    }
    private func removeInstanceData(_ id: UUID) {
        let path = disk.instance(id)
        guard let parent = try? path.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              parent.isDirectory == true, parent.isSymbolicLink != true,
              let info = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true else { return }
        guard !Self.lockHeld(at: path) else { return }
        if FileManager.default.fileExists(atPath: path.path) {
            do { try FileManager.default.removeItem(at: path) }
            catch { NSLog("Cannot remove retired pet data: %@", error.localizedDescription) }
        }
    }
    private func pruneRetiredInstances() {
        guard settingsReadable else { return }
        let folder = disk.directory.appendingPathComponent("Instances", isDirectory: true)
        guard let info = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true else { return }
        let retained = Set(preferences.pets.map(\.id)).union(pets.map(\.id))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for path in entries {
            guard let id = UUID(uuidString: path.lastPathComponent), !retained.contains(id),
                  let info = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else { continue }
            removeInstanceData(id)
        }
        let replies = disk.directory.appendingPathComponent("Replies", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: replies, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? [] {
            guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  info.isRegularFile == true, let changed = info.contentModificationDate,
                  changed < Date(timeIntervalSinceNow: -60) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func refresh() {
        for index in pets.indices {
            let path = disk.instance(pets[index].id).appendingPathComponent("status.json")
            guard let data = try? Data(contentsOf: path),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawID = report["instanceID"] as? String,
                  UUID(uuidString: rawID) == pets[index].id,
                  (report["pid"] as? Int) == Int(pets[index].process.processIdentifier) else { continue }
            pets[index].report = report
            let kind = pets[index].spec.kind
            if !pets[index].stopping && !pendingSizes.contains(kind) {
                if report["sizeSetting"] as? String == "independent", let width = report["petWidth"] as? Int {
                    if customWidths[kind.rawValue] != width { customWidths[kind.rawValue] = width; savePreferences() }
                } else if report["sizeSetting"] as? String == "follow-codex", customWidths[kind.rawValue] != nil {
                    customWidths.removeValue(forKey: kind.rawValue)
                    savePreferences()
                }
            }
        }
        refreshInteractions()
        pruneCounter += 1
        if pruneCounter <= 10 || pruneCounter % 30 == 0 { pruneRetiredInstances() }
        writeStatus()
    }
    private func savePreferences() {
        guard settingsReadable else { return }
        preferences.widths = customWidths
        do { try JSONEncoder().encode(preferences).write(to: disk.preferences, options: .atomic) }
        catch { NSLog("Hub preferences: %@", error.localizedDescription) }
    }
    func writeStatus() {
        let rows: [[String: Any]] = pets.map { pet in
            ["id": pet.id.uuidString, "kind": pet.spec.kind.rawValue, "title": pet.spec.title,
             "pid": pet.process.processIdentifier, "slot": pet.spec.slot, "running": pet.process.isRunning,
             "stopping": pet.stopping, "engine": pet.report]
        }
        var report: [String: Any] = ["app": hubIdentity, "pid": ProcessInfo.processInfo.processIdentifier,
                                     "running": !closing, "petCount": rows.count, "pets": rows,
                                     "menuBarIcon": false, "restoreOnLaunch": restoreOnLaunch]
        report["restoring"] = restoring
        report["closing"] = closing
        report["pendingDismissals"] = dismissalCompletions.count
        report["maximumPerKind"] = 1
        report["socialEnabled"] = socialEnabled
        report["interactionCompleted"] = interactionCompleted
        report["interactionCancelled"] = interactionCancelled
        if let session = pairSession {
            report["interaction"] = ["id": session.plan.id.uuidString,
                "behavior": session.plan.behavior.rawValue, "title": session.plan.behavior.title,
                "startAt": session.plan.startAt, "duration": session.plan.duration,
                "motionDuration": session.plan.motionDuration,
                "dialogueScript": session.plan.dialogueScript ?? "",
                "gap": PairInteractionPlan.gap(session.plan.origins[0], session.plan.origins[1])]
        } else { report["interaction"] = NSNull() }
        report["widths"] = customWidths
        report["lastCommand"] = lastCommand
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: disk.status, options: .atomic)
        }
    }
    func receive(_ command: [AnyHashable: Any]) {
        guard let action = command["action"] as? String,
              let token = command["request"] as? String, UUID(uuidString: token) != nil else { return }
        let value = command["value"] as? String
        func reply(_ ok: Bool, _ message: String? = nil) {
            var response: [String: Any] = ["request": token, "ok": ok]
            response["error"] = message
            lastCommand = response
            writeStatus()
            let target = disk.reply(token)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: disk.snapshot(), options: [.sortedKeys])
                    .write(to: target, options: .atomic)
            } catch { NSLog("Hub command reply: %@", error.localizedDescription) }
        }
        do {
            switch action {
            case "status": reply(true)
            case "show": onReveal?(); reply(true)
            case "summon":
                guard let value, let kind = PetKind(rawValue: value) else { throw failure("请选择有效的伙伴。") }
                let count = command["count"] as? Int ?? 1
                guard count == 1 else { throw failure("每种伙伴最多召唤一只。") }
                try summonChecked(kind)
                reply(true)
            case "interact":
                let parts = value?.split(separator: ":").map(String.init) ?? []
                guard (1...2).contains(parts.count), let behavior = SocialBehavior(rawValue: parts[0]),
                      parts.count == 1 || PetKind(rawValue: parts[1]) != nil else { throw failure("请选择互动动作。") }
                try beginInteraction(behavior, initiator: parts.count == 2 ? PetKind(rawValue: parts[1]) : nil)
                reply(true)
            case "cancel-interaction": cancelInteraction(); reply(true)
            case "social":
                guard value == "on" || value == "off" else { throw failure("互动设置无效。") }
                socialEnabled = value == "on"
                reply(true)
            case "size":
                guard let value else { throw failure("请选择伙伴和大小。") }
                let parts = value.split(separator: ":").map(String.init)
                guard parts.count == 2, let kind = PetKind(rawValue: parts[0]) else { throw failure("大小参数无效。") }
                let width = parts[1] == "follow" ? nil : Int(parts[1])
                guard parts[1] == "follow" || width.map({ (80...224).contains($0) }) == true else { throw failure("大小范围为80至224。") }
                setSize(kind, width: width)
                reply(true)
            case "dismiss":
                guard let value, let id = UUID(uuidString: value), pets.contains(where: { $0.id == id }) else { throw failure("这位伙伴已收回。") }
                dismiss(id) { reply(true) }
            case "dismiss-all": dismissAll { reply(true) }
            case "quit":
                reply(true)
                NSApp.terminate(nil)
            default: throw failure("不支持的操作。")
            }
        } catch { reply(false, error.localizedDescription) }
    }
}

struct PetPortrait: View {
    let kind: PetKind
    var dragonArtwork: URL?
    private var image: NSImage? {
        let url = kind == .dragon
            ? dragonArtwork?.appendingPathComponent("Frames/idle/00.png")
            : Bundle.main.url(forResource: kind.preview, withExtension: nil)
        return url.flatMap { NSImage(contentsOf: $0) }
    }
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "pawprint.fill").resizable().scaledToFit().foregroundStyle(kind.color)
        }
    }
}

struct PetSizeView: View {
    @ObservedObject var store: HubStore
    let kind: PetKind
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("大小").font(.system(size: 11, weight: .medium))
                Text("\(store.width(for: kind))").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(store.customWidths[kind.rawValue] == nil ? "已同步尺寸" : "同步 Codex 大小") {
                    store.setSize(kind, width: nil)
                }
                .buttonStyle(.plain).font(.system(size: 10))
                .foregroundStyle(kind.color)
                .disabled(store.customWidths[kind.rawValue] == nil)
                .accessibilityLabel("\(kind.name) 跟随 Codex 大小")
            }
            Slider(value: Binding(
                get: { Double(store.width(for: kind)) },
                set: { store.setSize(kind, width: Int($0.rounded())) }),
                   in: 80...224, step: 1)
                .tint(kind.color)
                .accessibilityLabel("\(kind.name) 大小")
        }
        .padding(.top, 7)
    }
}

struct HubView: View {
    @ObservedObject var store: HubStore
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("桌宠伙伴").font(.system(size: 29, weight: .bold, design: .rounded))
                    Text("想让谁来陪你？").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.pets.count) 只已召唤").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Color.white.opacity(0.85), in: Capsule())
            }
            HStack(spacing: 18) {
                ForEach(PetKind.allCases, id: \.self) { kind in
                    VStack(spacing: 10) {
                        PetPortrait(kind: kind, dragonArtwork: store.dragonArtwork).frame(height: 118)
                        Text(kind.name).font(.system(size: 19, weight: .bold))
                        Text(kind.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        if kind == .dragon && !store.isSummoned(.dragon) {
                            Button(store.dragonArtwork == nil ? "导入白龙素材" : "更换白龙素材") { store.importDragonArtwork() }
                                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(kind.color)
                        }
                        Button { store.summon(kind) } label: {
                            Label(store.isSummoned(kind) ? "已在桌面" : "召唤",
                                  systemImage: store.isSummoned(kind) ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .background(kind.color, in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityLabel(store.isSummoned(kind) ? "\(kind.name) 已在桌面" : "召唤 \(kind.name)")
                        .disabled(store.restoring || store.isSummoned(kind))
                        .opacity(store.isSummoned(kind) ? 0.6 : 1)
                        PetSizeView(store: store, kind: kind)
                            .disabled(store.restoring || store.pets.contains(where: {
                                $0.spec.kind == kind && ($0.stopping || $0.report.isEmpty)
                            }))
                    }
                    .padding(18).frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [.white, kind.color.opacity(0.065)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 21))
                    .overlay(RoundedRectangle(cornerRadius: 21).stroke(kind.color.opacity(0.12), lineWidth: 1))
                }
            }
            HStack {
                Text("桌面上的伙伴").font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu("一起玩") {
                    Section("近距离") {
                        ForEach(SocialBehavior.allCases.filter(\.shortDistance), id: \.self) { behavior in
                            Button(behavior.title) { store.interact(behavior) }
                        }
                    }
                    Section("中长距离") {
                        ForEach(SocialBehavior.allCases.filter { !$0.shortDistance }, id: \.self) { behavior in
                            Button(behavior.title) { store.interact(behavior) }
                        }
                    }
                    if store.interactionTitle != nil {
                        Divider()
                        Button("结束互动") { store.cancelInteraction() }
                    }
                }.disabled(store.pets.count != 2 || store.restoring)
                Button("一起召唤") { store.summonTogether() }
                    .accessibilityLabel("一起召唤白龙和大肥鱼")
                    .disabled(store.restoring || store.pets.count == 2)
                Button("全部收回") { store.dismissAll() }
                    .disabled(store.pets.isEmpty && !store.restoring).accessibilityLabel("收回全部桌宠")
            }
            if let interaction = store.interactionTitle {
                Text("正在一起玩 · " + interaction).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if store.pets.isEmpty {
                VStack(spacing: 8) {
                    if store.restoring { ProgressView().controlSize(.small) }
                    else { Image(systemName: "sparkles").font(.system(size: 23)).foregroundStyle(Color.gray.opacity(0.5)) }
                    Text(store.restoring ? "正在恢复伙伴" : "伙伴们正在等你召唤")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 17))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.pets) { pet in
                            HStack(spacing: 12) {
                                PetPortrait(kind: pet.spec.kind, dragonArtwork: store.dragonArtwork).frame(width: 43, height: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pet.spec.title).font(.system(size: 13, weight: .semibold))
                                    Text(pet.description).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("找到她") { store.reveal(pet.id) }.disabled(pet.stopping)
                                    .accessibilityLabel("找到 \(pet.spec.title)")
                                Button("收回") { store.dismiss(pet.id) }.disabled(pet.stopping)
                                    .accessibilityLabel("收回 \(pet.spec.title)")
                            }
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Toggle("下次打开时恢复伙伴", isOn: $store.restoreOnLaunch).toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Toggle("空闲时互相玩耍", isOn: $store.socialEnabled).toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Text("拖动可移动，悬停可互动").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(27)
        .frame(minWidth: 670, minHeight: 700)
        .background(LinearGradient(colors: [Color(red: 0.97, green: 0.965, blue: 0.98),
                                           Color(red: 0.945, green: 0.96, blue: 0.985)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(Color(red: 0.16, green: 0.19, blue: 0.27))
        .preferredColorScheme(.light)
        .alert("桌宠伙伴", isPresented: Binding(get: { store.errorMessage != nil },
                                             set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

final class HubDelegate: NSObject, NSApplicationDelegate {
    let store: HubStore
    private var window: NSWindow?
    init(store: HubStore) { self.store = store }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        store.onReveal = { [weak self] in self?.reveal() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: commandName, object: store.disk.directory.path)
        store.start()
        if !CommandLine.arguments.contains("--background") { reveal() }
    }
    private func makeMenu() {
        let bar = NSMenu()
        let app = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "关于桌宠伙伴", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示桌宠伙伴", action: #selector(showWindow), keyEquivalent: "1").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出并收回桌宠", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = menu
        bar.addItem(app)
        NSApp.mainMenu = bar
    }
    @objc private func showWindow() { reveal() }
    func reveal() {
        if window == nil {
            let content = NSHostingView(rootView: HubView(store: store))
            let pane = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 805),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            pane.title = "桌宠伙伴"
            pane.titlebarAppearsTransparent = true
            pane.isReleasedWhenClosed = false
            pane.contentView = content
            pane.minSize = NSSize(width: 680, height: 740)
            pane.center()
            window = pane
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func command(_ note: Notification) {
        if let values = note.userInfo { store.receive(values) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reveal()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.stopForApplicationExit()
        return .terminateNow
    }
}

private func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func run() throws {
    let disk = try HubDisk()
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        print("桌宠伙伴\n--status\n--summon dragon|whale\n--size dragon|whale 80..224|follow\n--dismiss UUID\n--dismiss-all\n--show\n--quit\n--background\n--interact highfive|nuzzle|duet|beckon|starpass|chase\n--cancel-interaction\n--social on|off\n--import-dragon PATH")
        return
    }
    if args.first == "--import-dragon", args.count == 2 {
        guard let lock = try disk.claim() else { throw failure("请先退出桌宠伙伴再从命令行导入，或使用窗口中的导入按钮。") }
        defer { close(lock) }
        let chosen = URL(fileURLWithPath: args[1], isDirectory: true)
        let candidates = [chosen, chosen.appendingPathComponent("Contents/Resources"),
            chosen.appendingPathComponent("Contents/Resources/Engines/GPT白龙.app/Contents/Resources")]
        guard let source = candidates.first(where: { DragonArtwork.isValid($0) }) else {
            throw failure("没有找到完整的白龙动画，原有素材已保留。")
        }
        try DragonArtwork.install(source, to: disk.directory.appendingPathComponent("DragonArtwork"))
        try printJSON(["imported": true, "frames": DragonArtwork.files.count])
        return
    }
    if !args.isEmpty && args != ["--background"] {
        let action: String
        var value: String?
        var count = 1
        switch args {
        case ["--status"]: action = "status"
        case ["--show"]: action = "show"
        case ["--quit"]: action = "quit"
        case ["--dismiss-all"]: action = "dismiss-all"
        default:
            if args.first == "--interact", args.count == 2 || args.count == 3 {
                action = "interact"; value = args.count == 3 ? args[1] + ":" + args[2] : args[1]
            } else if args == ["--cancel-interaction"] {
                action = "cancel-interaction"
            } else if args.first == "--social", args.count == 2 {
                action = "social"; value = args[1]
            } else if args.first == "--summon", args.count == 2 || args.count == 4 {
                action = "summon"; value = args[1]
                if args.count == 4 {
                    guard args[2] == "--count", let n = Int(args[3]) else { throw failure("数量无效。") }
                    count = n
                }
            } else if args.first == "--dismiss", args.count == 2 {
                action = "dismiss"; value = args[1]
            } else if args.first == "--size", args.count == 3 {
                action = "size"; value = args[1] + ":" + args[2]
            } else { throw failure("参数无效，请使用 --help。") }
        }
        guard let report = disk.send(action, value: value, count: count) else {
            if action == "status" { try printJSON(["running": false, "petCount": 0]); return }
            throw failure("请先打开桌宠伙伴。")
        }
        try printJSON(report)
        if (report["lastCommand"] as? [String: Any])?["ok"] as? Bool != true { exit(1) }
        return
    }
    guard let fd = try disk.claim() else { _ = disk.send("show"); return }
    defer { close(fd) }
    let application = NSApplication.shared
    let store = HubStore(disk: disk)
    let delegate = HubDelegate(store: store)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

do { try run() }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
