import AVFAudio
import Foundation

struct WhaleVoiceLine: Decodable, Equatable {
    let text: String
    let file: String
}

struct WhaleDialogueRequest: Decodable, Equatable {
    enum Speaker: String, Decodable { case dragon, whale }

    struct Turn: Decodable, Equatable {
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

    func fits(sceneDuration: TimeInterval) -> Bool {
        guard turns.count == 3 else { return false }
        var nextOffset: TimeInterval = 0
        for turn in turns {
            guard (0.15...10).contains(turn.duration), turn.offset >= nextOffset else { return false }
            nextOffset = turn.offset + turn.duration + 0.24
        }
        return nextOffset <= sceneDuration
    }
}

struct WhaleDialogueRecording {
    let turn: WhaleDialogueRequest.Turn
    let player: AVAudioPlayer
}

private struct WhaleDialogueCatalog: Decodable {
    struct Script: Decodable {
        struct Line: Decodable {
            let index: Int
            let speaker: WhaleDialogueRequest.Speaker
            let text: String
            let file: String
            let duration: TimeInterval
        }

        let behavior: String
        let initiator: WhaleDialogueRequest.Speaker
        let turns: [Line]
    }

    let version: Int
    let scripts: [String: Script]

    func recordings(for request: WhaleDialogueRequest, behavior: String, initiator: WhaleDialogueRequest.Speaker,
                    directory: URL) -> [WhaleDialogueRecording]? {
        guard version == 1, request.script == "\(behavior)-\(initiator.rawValue)",
              let script = scripts[request.script], script.behavior == behavior, script.initiator == initiator,
              request.turns.count == 3, script.turns.count == request.turns.count else { return nil }
        for (index, pair) in zip(request.turns, script.turns).enumerated() {
            let (turn, line) = pair
            let speaker = index == 1 ? (initiator == .whale ? .dragon : .whale) : initiator
            guard turn.index == index, line.index == index, turn.speaker == speaker, line.speaker == speaker,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, turn.text == line.text,
                  line.file == "\(request.script)-\(index).wav", turn.file == line.file,
                  abs(turn.duration - line.duration) < 0.0005 else { return nil }
        }
        var recordings: [WhaleDialogueRecording] = []
        for turn in request.turns where turn.speaker == .whale {
            guard let player = try? AVAudioPlayer(contentsOf: directory.appendingPathComponent(turn.file)),
                  player.duration.isFinite, abs(player.duration - turn.duration) < 0.015,
                  player.prepareToPlay() else { return nil }
            recordings.append(.init(turn: turn, player: player))
        }
        return recordings
    }
}

struct WhaleVoiceCatalog {
    private struct Manifest: Decodable {
        let version: Int
        let lines: [String: [WhaleVoiceLine]]
    }

    let lines: [String: [WhaleVoiceLine]]
    let directory: URL

    init(resources: URL) throws {
        directory = resources.appendingPathComponent("Voice", isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let keys = Set(Pose.actions.map(\.rawValue) + ["task_done"])
        guard manifest.version == 1, Set(manifest.lines.keys) == keys else {
            throw AssetError("语音清单需要包含所有表情和任务完成提醒")
        }
        var seenFiles = Set<String>()
        for (key, variants) in manifest.lines {
            guard !variants.isEmpty else { throw AssetError("缺少台词 " + key) }
            for line in variants {
                guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      line.file == (line.file as NSString).lastPathComponent, line.file.hasSuffix(".wav"),
                      !line.file.hasPrefix("."), seenFiles.insert(line.file).inserted else {
                    throw AssetError("台词或配音文件名无效 " + key)
                }
            }
        }
        lines = manifest.lines
    }

    func verify() throws {
        for variants in lines.values {
            for line in variants {
                let sound = try AVAudioPlayer(contentsOf: directory.appendingPathComponent(line.file))
                guard sound.duration.isFinite, sound.duration > 0 else { throw AssetError("录音没有时长 " + line.file) }
            }
        }
    }
}

final class WhaleSpeech {
    private let catalog: WhaleVoiceCatalog?
    private let catalogError: String?
    private let outputVolume: Float
    private let dialogueVolume: Float
    private let dialogueDirectory: URL
    private let dialogueCatalog: WhaleDialogueCatalog?
    private var previousFile: [String: String] = [:]
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var event: String?
    private var duration: TimeInterval = 0
    private var captionDuration: TimeInterval = 0
    private var started = false
    private var error: String?
    private(set) var line: WhaleVoiceLine?
    private(set) var dialogueWasMuted = false
    var onChange: (() -> Void)?
    var muted = false {
        didSet {
            guard muted != oldValue else { return }
            if muted {
                if event == "dialogue" { dialogueWasMuted = true }
                audio?.stop()
                audio = nil
            }
            onChange?()
        }
    }

    init(resources: URL, quietTest: Bool = false) {
        outputVolume = quietTest ? 0 : 1
        let environment = ProcessInfo.processInfo.environment
        let quietDialogueTest = environment["DESKTOP_PET_MANAGED"] == "1"
            && environment["DESKTOP_PET_HUB_QUIET"] == "1" && environment["DESKTOP_PET_AUDIO_TEST_SILENT"] == "1"
        dialogueVolume = quietDialogueTest ? 0 : outputVolume
        let directory = resources.appendingPathComponent("Dialogue", isDirectory: true)
        dialogueDirectory = directory
        dialogueCatalog = (try? Data(contentsOf: directory.appendingPathComponent("manifest.json"))).flatMap {
            try? JSONDecoder().decode(WhaleDialogueCatalog.self, from: $0)
        }
        do {
            catalog = try WhaleVoiceCatalog(resources: resources)
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = error.localizedDescription
        }
    }

    func prepareDialogue(_ request: WhaleDialogueRequest, behavior: String,
                         initiator: WhaleDialogueRequest.Speaker) -> [WhaleDialogueRecording]? {
        dialogueCatalog?.recordings(for: request, behavior: behavior, initiator: initiator, directory: dialogueDirectory)
    }

    func speakDialogue(_ recording: WhaleDialogueRecording) -> Bool {
        reset()
        let sound = recording.player
        sound.volume = dialogueVolume
        if !muted {
            guard sound.play() else { return false }
            audio = sound
            started = true
        }
        dialogueWasMuted = muted
        event = "dialogue"
        line = WhaleVoiceLine(text: recording.turn.text, file: recording.turn.file)
        duration = sound.duration
        captionDuration = duration
        return true
    }

    func stopDialogue() {
        if event == "dialogue" { reset() }
    }

    func speak(_ key: String) {
        reset()
        guard let catalog, let variants = catalog.lines[key] else {
            error = catalogError ?? "无法找到台词 " + key
            onChange?()
            return
        }
        let choices = variants.count > 1 ? variants.filter { $0.file != previousFile[key] } : variants
        guard let selected = choices.randomElement() else { return }
        previousFile[key] = selected.file
        event = key
        line = selected
        do {
            let sound = try AVAudioPlayer(contentsOf: catalog.directory.appendingPathComponent(selected.file))
            duration = sound.duration
            if !muted {
                sound.volume = outputVolume
                audio = sound
                started = sound.play()
                if !started { error = "无法播放语音 " + selected.file }
            }
        } catch {
            self.error = "无法打开语音 " + selected.file + "：" + error.localizedDescription
        }
        let reading = min(2.8, max(1.25, 0.40 + Double(selected.text.count) * 0.095))
        captionDuration = max(reading, duration + 0.20)
        scheduleExpiry(after: captionDuration)
        onChange?()
    }

    var status: [String: Any] {
        ["event": event as Any? ?? NSNull(), "file": line?.file as Any? ?? NSNull(),
         "text": line?.text as Any? ?? NSNull(), "durationMs": Int((duration * 1000).rounded()),
         "captionDurationMs": Int((captionDuration * 1000).rounded()), "started": started,
         "playing": audio?.isPlaying ?? false, "muted": muted,
         "error": (error ?? catalogError) as Any? ?? NSNull()]
    }

    func interrupt() {
        guard line != nil || audio != nil else { return }
        reset()
        onChange?()
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        audio?.stop()
        audio = nil
        event = nil
        line = nil
        duration = 0
        captionDuration = 0
        started = false
        error = nil
        dialogueWasMuted = false
    }

    private func scheduleExpiry(after delay: TimeInterval) {
        timer?.invalidate()
        let next = Timer(fire: Date(timeIntervalSinceNow: delay), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            // A slow audio device may finish later than the decoded PCM duration.
            if self.audio?.isPlaying == true { self.scheduleExpiry(after: 0.12); return }
            self.reset()
            self.onChange?()
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
