import AVFAudio
import Foundation

struct WhaleVoiceLine: Decodable, Equatable {
    let text: String
    let file: String
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
    private var previousFile: [String: String] = [:]
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var event: String?
    private var duration: TimeInterval = 0
    private var captionDuration: TimeInterval = 0
    private var started = false
    private var error: String?
    private(set) var line: WhaleVoiceLine?
    var onChange: (() -> Void)?
    var muted = false {
        didSet {
            guard muted != oldValue else { return }
            if muted { audio?.stop(); audio = nil }
            onChange?()
        }
    }

    init(resources: URL, quietTest: Bool = false) {
        outputVolume = quietTest ? 0 : 1
        do {
            catalog = try WhaleVoiceCatalog(resources: resources)
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = error.localizedDescription
        }
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
