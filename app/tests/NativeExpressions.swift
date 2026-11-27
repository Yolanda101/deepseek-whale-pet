import AppKit
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ reason: String) { description = reason }
}

private func require(_ value: Bool, _ reason: String) throws {
    if !value { throw Failure(reason) }
}

private func spin(_ seconds: TimeInterval) {
    let end = Date(timeIntervalSinceNow: seconds)
    repeat { RunLoop.main.run(until: min(end, Date(timeIntervalSinceNow: 0.005))) } while Date() < end
}

private func wait(_ reason: String, seconds: TimeInterval = 3, until condition: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(reason) }
        spin(0.005)
    }
}

@main
private struct NativeExpressionsFixture {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            exit(1)
        }
    }

    private static func verifyVoiceVariants(_ resources: URL, catalog: WhaleVoiceCatalog) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = temp.appendingPathComponent("Voice")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var lines: [String: [[String: String]]] = [:]
        for (key, entries) in catalog.lines {
            for entry in entries {
                try fm.createSymbolicLink(at: folder.appendingPathComponent(entry.file),
                                         withDestinationURL: catalog.directory.appendingPathComponent(entry.file))
            }
            lines[key] = entries.map { ["text": $0.text, "file": $0.file] }
        }
        let first = catalog.lines["greeting"]![0]
        let alternate = catalog.lines["task_done"]![0]
        let alternateName = UUID().uuidString + ".wav"
        try fm.createSymbolicLink(at: folder.appendingPathComponent(alternateName),
                                 withDestinationURL: catalog.directory.appendingPathComponent(alternate.file))
        lines["greeting"] = [["text": first.text, "file": first.file], ["text": alternate.text, "file": alternateName]]
        try JSONSerialization.data(withJSONObject: ["version": 1, "lines": lines])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let speech = WhaleSpeech(resources: temp, quietTest: true)
        let candidates = [first, WhaleVoiceLine(text: alternate.text, file: alternateName)]
        speech.speak("greeting")
        let initial = try requireLine(speech)
        try require(candidates.contains(initial), "第一组字幕与文件不配对")
        speech.speak("greeting")
        let second = try requireLine(speech)
        try require(second != initial && candidates.contains(second), "同一动作切换变体时字幕或音频未同时变化")
        speech.muted = true
        try require(speech.status["playing"] as? Bool == false && speech.line == second, "播放中静音未即时生效，或字幕消失")
        speech.muted = false
        try require(speech.status["playing"] as? Bool == false && speech.line == second, "取消静音重放了前一句")
        speech.speak("dance")
        _ = try requireLine(speech)
        let expiry = Double(speech.status["captionDurationMs"] as! Int) / 1000
        spin(expiry * 0.65)
        speech.speak("greeting")
        let replacement = try requireLine(speech)
        let nextExpiry = Double(speech.status["captionDurationMs"] as! Int) / 1000
        spin(min(expiry * 0.35 + 0.04, nextExpiry * 0.90))
        try require(speech.line == replacement, "上一句的计时器清掉了新字幕")
        try wait("配音播完后字幕未到期收起", seconds: nextExpiry + 1.5) { speech.line == nil }
        speech.muted = true
        speech.speak("task_done")
        try require(speech.status["started"] as? Bool == false && speech.line != nil, "静音模式启动了配音或漏了字幕")
        speech.interrupt()
        try require(speech.status["playing"] as? Bool == false && speech.line == nil, "中断后字幕或音频仍在")
    }

    private static func requireLine(_ speech: WhaleSpeech) throws -> WhaleVoiceLine {
        guard let line = speech.line, speech.status["started"] as? Bool == true,
              speech.status["playing"] as? Bool == true else { throw Failure("播放器未正常启动 " + String(describing: speech.status)) }
        return line
    }

    private static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 3, let screen = NSScreen.screens.first,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Failure("需要 macOS 图形会话、资源目录和结果文件")
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        let library = AnimationLibrary(resources: resources)
        let voices = try WhaleVoiceCatalog(resources: resources)
        try voices.verify()
        try verifyVoiceVariants(resources, catalog: voices)
        try ExpressionPanel.verifyIcons(at: resources)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            resources.appendingPathComponent("Frames/figurine/manifest.json"))) as! [String: Any]
        let states = manifest["states"] as! [String: [String: Any]]
        let fake = PetPanel(overlaySize: NSSize(width: 139, height: 151), title: "原生鲸测试目标")
        fake.alphaValue = 0
        fake.ignoresMouseEvents = true
        fake.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 90, y: screen.visibleFrame.midY - 76))
        fake.orderFrontRegardless()
        defer { fake.orderOut(nil) }
        let outside = NSPoint(x: -100_000, y: -100_000)
        let body = NSPoint(x: fake.frame.midX, y: fake.frame.midY)
        var pointer = outside
        var buttons = 0
        var target: NativePetLocation? = NativePetLocation(frame: fake.frame, windowID: CGWindowID(fake.windowNumber),
                                                           displayID: display.uint32Value)
        let player = NativeWhaleInteraction(library: library, resources: resources, locate: { target },
                                            pointer: { pointer }, pressedButtons: { buttons }, offscreen: true)
        player.muted = false
        player.start()
        defer { player.stop() }
        var report: [String: Any] { player.status }
        var menu: [String: Any] { report["menu"] as! [String: Any] }
        func items() -> [[String: Any]] { menu["items"] as! [[String: Any]] }
        func point(_ box: [String: Any]) -> NSPoint {
            NSPoint(x: box["x"] as! CGFloat + (box["width"] as! CGFloat) / 2,
                    y: box["y"] as! CGFloat + (box["height"] as! CGFloat) / 2)
        }
        func click(_ title: String) throws {
            guard let number = menu["windowNumber"] as? Int, let window = application.window(withWindowNumber: number),
                  let controls = window.contentView?.subviews.compactMap({ $0 as? NSButton }),
                  let button = controls.first(where: { $0.accessibilityLabel() == title || $0.title == title }),
                  button.isEnabled, !button.isHidden, window.alphaValue == 0, window.ignoresMouseEvents else {
                throw Failure("无法在隐藏的真实 AppKit 面板上点选 " + title)
            }
            pointer = point(screenRectValues(window.convertToScreen(button.convert(button.bounds, to: nil))))
            button.performClick(nil)
        }
        func enter() throws {
            pointer = outside
            spin(0.07)
            pointer = body
            try wait("身体未打开菜单") { menu["visible"] as? Bool == true && menu["page"] as? Int == 1 }
            try require(items().compactMap { $0["pose"] as? String } == Array(Pose.expressions.prefix(6)).map(\.rawValue),
                        "第一页六项顺序")
            try require(Set(items().compactMap { $0["x"] as? CGFloat }).count == 2 &&
                        Set(items().compactMap { $0["y"] as? CGFloat }).count == 3, "第一页不是两列三行")
        }
        func forward() throws {
            try click("下一页")
            try require(menu["page"] as? Int == 2, "翻页后面板页号错误")
            try require(items().compactMap { $0["pose"] as? String } == ["tailwag", "feeding", "outing", "crying", "rice", "remorse"],
                        "第二页六项顺序")
            try require(items().compactMap { $0["title"] as? String }.suffix(2) == ["吃大白饭", "很愧疚"] &&
                        Pose.remorse.actionTitle == "犯错后很愧疚", "新动作名称")
            try require(Set(items().compactMap { $0["x"] as? CGFloat }).count == 2 &&
                        Set(items().compactMap { $0["y"] as? CGFloat }).count == 3, "第二页不是两列三行")
        }
        try wait("测试目标定位") { report["targetVisible"] as? Bool == true }
        pointer = NSPoint(x: fake.frame.minX + 1, y: fake.frame.maxY - 1)
        spin(0.28)
        try require(menu["visible"] as? Bool == false, "透明角落触发菜单")
        try enter()
        try forward()
        try click("上一页")
        try require(menu["page"] as? Int == 1, "没有返回第一页")
        pointer = outside
        try wait("移开应收起面板") { menu["visible"] as? Bool == false }
        var records: [[String: Any]] = []
        func play(_ pose: Pose, stalled: Bool = false) throws {
            try enter()
            if Pose.expressions.firstIndex(of: pose)! >= 6 { try forward() }
            try click(pose.expressionTitle)
            try wait("未开始 " + pose.rawValue) { report["pose"] as? String == pose.rawValue }
            let observedStart = ProcessInfo.processInfo.systemUptime
            let count = states[pose.rawValue]!["frameCount"] as! Int
            let durations = states[pose.rawValue]!["frameDurationsMs"] as! [Int]
            try require(report["frameIndex"] as? Int == 0 && report["frameCount"] as? Int == count, "首帧或帧总数错误")
            try require(report["overlayVisible"] as? Bool == true && menu["visible"] as? Bool == false, "动作板未替换菜单")
            let voice = report["voice"] as! [String: Any]
            let caption = report["caption"] as? String
            let pair = WhaleVoiceLine(text: voice["text"] as? String ?? "", file: voice["file"] as? String ?? "")
            let voiceMs = voice["durationMs"] as! Int
            try require(voice["event"] as? String == pose.rawValue && caption == pair.text &&
                        voices.lines[pose.rawValue]!.contains(pair), "表情的字幕与录音未匹配 " + pose.rawValue)
            try require(voice["started"] as? Bool == true && voice["playing"] as? Bool == true &&
                        voice["error"] is NSNull && voiceMs > 0 && (voice["captionDurationMs"] as! Int) >= voiceMs,
                        "表情配音未开始或字幕显示时间不足 " + pose.rawValue)
            let overlay = application.window(withWindowNumber: report["overlayWindowNumber"] as! Int)!
            try require(overlay.frame == fake.frame && overlay.ignoresMouseEvents && overlay.alphaValue == 0,
                        "测试动作板位置或穿透有误")
            var sequence = [0]
            if stalled { Thread.sleep(forTimeInterval: 0.38) }
            try wait("动作未结束 " + pose.rawValue, seconds: 8) {
                let index = report["frameIndex"] as! Int
                if index >= 0 && index != sequence.last { sequence.append(index) }
                return report["pose"] is NSNull
            }
            try require(sequence == Array(0..<count), "逐帧顺序或完整性错误 " + pose.rawValue + " " + String(describing: sequence))
            var last = report["lastPlayback"] as! [String: Any]
            let measured = last["durationMs"] as! Int
            let expected = durations.reduce(0, +)
            let delayed = last["delayCompensationMs"] as! Int
            try require(last["visitedFrameCount"] as? Int == count && last["lastFrameIndex"] as? Int == count - 1,
                        "实际播放器漏帧")
            try require(measured >= expected - 1 && measured < expected + delayed + 160, "实际结束时间有误")
            try require((last["lastFrameHeldMs"] as! Int) >= durations.last! - 35, "最后一个姿势过早撤去")
            if stalled { try require(delayed > 150 && measured > expected + 150, "没有补偿主线程延迟") }
            try require(!overlay.isVisible && report["overlayVisible"] as? Bool == false, "播完仍有遮挡")
            if voiceMs > measured + 60 {
                let after = report["voice"] as! [String: Any]
                try require(report["caption"] as? String == caption && after["playing"] as? Bool == true,
                            "动作结束时截断了录音 " + pose.rawValue)
                last["voiceContinuedAfterAnimation"] = true
            }
            if pose == .hungry || pose == .angry {
                try wait(pose.expressionTitle + "台词播放未结束", seconds: Double(voiceMs) / 1000 + 2) {
                    (report["voice"] as? [String: Any])?["playing"] as? Bool == false
                }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - observedStart) * 1000)
                try require(elapsed >= voiceMs - 90, pose.expressionTitle + "台词未播到文件结尾")
                try wait(pose.expressionTitle + "台词结束后字幕仍未收起", seconds: 2) { report["caption"] is NSNull }
                last["observedVoiceEndMs"] = elapsed
            }
            last["voice"] = voice
            last["observedSequence"] = sequence
            last["deliberateStall"] = stalled
            records.append(last)
            print(pose.rawValue, count, measured, "ms", "delay", delayed)
        }
        for pose in Pose.expressions { try play(pose) }
        try play(.tailwag, stalled: true)
        try enter()
        try click(Pose.greeting.expressionTitle)
        try wait("断开前动作未开始") { report["pose"] as? String == "greeting" }
        try enter()
        try click(Pose.dance.expressionTitle)
        try wait("中途点选新动作未同步更换配音和字幕") {
            report["pose"] as? String == "dance" && (report["voice"] as? [String: Any])?["event"] as? String == "dance"
        }
        target = nil
        try wait("目标消失没有清空所有原生窗口") {
            report["targetVisible"] as? Bool == false && report["overlayVisible"] as? Bool == false &&
                menu["visible"] as? Bool == false && report["pose"] is NSNull && report["caption"] is NSNull &&
                (report["voice"] as? [String: Any])?["playing"] as? Bool == false
        }
        target = NativePetLocation(frame: fake.frame, windowID: CGWindowID(fake.windowNumber), displayID: display.uint32Value)
        pointer = body
        buttons = 1
        spin(0.70)
        try require(menu["visible"] as? Bool == false, "原生拖动时弹出表情面板")
        buttons = 0
        player.stop()
        try require(report["overlayVisible"] as? Bool == false && menu["visible"] as? Bool == false, "停止服务后有残余窗口")
        let result: [String: Any] = ["poses": records, "nativeTileWidth": 139, "nativeTileHeight": 151,
                                     "menuColumns": 2, "menuRows": 3, "pageItemCounts": [6, 6],
                                     "transparentCornerIgnored": true, "preservedNativeDrag": true,
                                     "targetDisappearanceClearedPlayback": true,
                                     "voicePairVariantsVerified": true, "muteSwitchAndExpiryVerified": true,
                                     "rapidReplacementVerified": true,
                                     "mouseSource": "fixture", "windowAlpha": 0, "audio": "real player at volume zero"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
    }
}
