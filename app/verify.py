#!/usr/bin/env python3
import argparse
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid


def app_status(binary, env, *command):
    result = subprocess.run([str(binary), *command], env=env, check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def wait_for(binary, env, description, expected, timeout=8):
    deadline = time.monotonic() + timeout
    while True:
        report = app_status(binary, env, "--status")
        if expected(report):
            print(description, flush=True)
            return report
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{description} {report}")
        time.sleep(0.10)


def smoke(bundle):
    binary = bundle / "Contents" / "MacOS" / "DeepSeekWhale"
    voices = json.loads((bundle / "Contents/Resources/Voice/manifest.json").read_bytes())["lines"]
    records = {}

    def matched_voice(status, key):
        voice = status.get("voice", {})
        return (voice.get("event") == key and voice.get("text") == status.get("caption") and
                any((v["file"], v["text"]) == (voice.get("file"), voice.get("text")) for v in voices[key]) and
                voice.get("error") is None and voice.get("started") is True and
                voice.get("captionDurationMs", 0) >= voice.get("durationMs", 0) > 0)

    assets = app_status(binary, os.environ, "--verify-assets")
    assert set(assets) == {"figurine", "original"}
    exclusive = ("tailwag", "angry", "dizzy", "hungry", "outing", "crying", "rice", "remorse")
    assert all(a in assets["figurine"] and a not in assets["original"] for a in exclusive)
    print(f"动态透明帧 {assets}", flush=True)

    with tempfile.TemporaryDirectory(prefix="deepseek-whale-smoke-") as path:
        directory = Path(path)
        data = directory / "pet"
        codex = directory / "codex"
        locks = codex / "thread-writer-locks"
        data.mkdir()
        locks.mkdir(parents=True)
        config = codex / "config.toml"
        config.write_text("[desktop]\navatar-overlay-mascot-width-px=143\n")
        (data / "preferences.json").write_text(json.dumps({
            "hidden": False, "roaming": True, "muted": False, "completionVoice": True, "skin": "model",
        }))
        env = {**os.environ, "WHALE_PET_DATA_DIR": str(data), "CODEX_HOME": str(codex), "WHALE_PET_UI_TEST": "1"}

        with closing(sqlite3.connect(codex / "thread_history_1.sqlite")) as db:
            db.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INT, rollout_ordinal INT)")
            db.commit()
            process = subprocess.Popen([str(binary)], env=env)
            try:
                idle = wait_for(binary, env, "旧皮肤偏好迁移和 Codex 宠物宽度同步",
                                lambda s: s.get("shownSkin") == "figurine" and s.get("visible") and
                                s.get("pose") == "idle" and s.get("petWidth") == 143, timeout=14)
                saved = json.loads((data / "preferences.json").read_text())
                assert saved["skin"] == "figurine" and saved["muted"] is False and saved["roaming"] and saved["completionVoice"]
                wait_for(binary, env, "待机时持续更新渲染帧",
                         lambda s: s.get("pose") == "idle" and s.get("frameIndex") != idle["frameIndex"])
                config.write_text("[desktop]\navatar-overlay-mascot-width-px=151\n")
                wait_for(binary, env, "运行中跟随 Codex 宽度修改",
                         lambda s: s.get("petWidth") == 151)

                thread_id = str(uuid.uuid4())
                with (locks / f"{thread_id}.lock").open("xb") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    db.execute("INSERT INTO thread_turns VALUES (?, 'inProgress', ?, 0)", (thread_id, int(time.time())))
                    db.commit()
                    wait_for(binary, env, "活动开始后显示工作动画",
                             lambda s: s.get("working") is True and s.get("pose") == "work")

                    for skin in ("original", "figurine"):
                        app_status(binary, env, "--skin", skin)
                        wait_for(binary, env, f"忙时完成形象切换 {skin}",
                                 lambda s: s.get("shownSkin") == skin and s.get("pose") == "work")
                        if skin == "original":
                            app_status(binary, env, "--action", "greeting")
                            wait_for(binary, env, "旧形象打招呼使用相同配音",
                                     lambda s: s.get("pose") == "greeting" and matched_voice(s, "greeting"))
                            for action in exclusive:
                                unavailable = subprocess.run([str(binary), "--action", action], env=env,
                                                             capture_output=True, text=True)
                                assert unavailable.returncode != 0

                    for count, action in enumerate(("greeting", "dance", "playful", "feeding", *exclusive), start=1):
                        command_at = time.monotonic()
                        app_status(binary, env, "--action", action)
                        start = wait_for(binary, env, f"播放 {action}",
                                         lambda s: s.get("pose") == action and s.get("working") is True and
                                         matched_voice(s, action) and s["voice"]["playing"] and s.get("petWidth") == 151)
                        stop = wait_for(binary, env, f"{action} 结束后继续工作",
                                        lambda s: s.get("completedActions") == count and s.get("pose") == "work", timeout=16)
                        records[action] = start["voice"]
                        elapsed_ms = (time.monotonic() - command_at) * 1000
                        if records[action]["durationMs"] > elapsed_ms + 180:
                            assert matched_voice(stop, action) and stop["voice"]["playing"], action
                            records[action]["voiceContinuedAfterAnimation"] = True
                        if action == "hungry":
                            wait_for(binary, env, "讨饭录音播完后字幕自然收起",
                                     lambda s: s["voice"]["event"] is None and s.get("caption") is None)
                            expired_ms = round((time.monotonic() - command_at) * 1000)
                            assert expired_ms >= records[action]["durationMs"] - 50
                            records[action]["observedCaptionExpiryMs"] = expired_ms

                    db.execute("UPDATE thread_turns SET status='completed'")
                    db.commit()
                    wait_for(binary, env, "活动完成后恢复待机",
                             lambda s: s.get("working") is False and s.get("pose") == "idle")
                    done = wait_for(binary, env, "任务完成提醒使用专属配音和对应字幕",
                                    lambda s: matched_voice(s, "task_done") and s["voice"]["playing"])
                    records["task_done"] = done["voice"]
                    app_status(binary, env, "--action", "tailwag")
                    wait_for(binary, env, "待机时甩尾巴", lambda s: s.get("pose") == "tailwag" and
                             matched_voice(s, "tailwag"))
                    app_status(binary, env, "--action", "greeting")
                    wait_for(binary, env, "甩尾中途切换为打招呼", lambda s: s.get("pose") == "greeting" and matched_voice(s, "greeting"))
                    wait_for(binary, env, "互动结束后回到待机", lambda s: s.get("pose") == "idle")
                    app_status(binary, env, "--action", "angry")
                    wait_for(binary, env, "待机时气鼓鼓甩尾", lambda s: s.get("pose") == "angry" and
                             matched_voice(s, "angry"))
                    wait_for(binary, env, "气鼓鼓甩尾结束后回到待机", lambda s: s.get("pose") == "idle")
                    app_status(binary, env, "--action", "dizzy")
                    wait_for(binary, env, "待机时播放累晕了", lambda s: s.get("pose") == "dizzy" and
                             matched_voice(s, "dizzy") and s["petWidth"] == 151)
                    wait_for(binary, env, "累晕了结束后回到待机", lambda s: s.get("pose") == "idle")
                    app_status(binary, env, "--action", "hungry")
                    wait_for(binary, env, "空闲时讨饭吃", lambda s: s.get("pose") == "hungry" and
                             matched_voice(s, "hungry"))
                    wait_for(binary, env, "讨饭结束后回到待机", lambda s: s.get("pose") == "idle")
                    for action in ("rice", "remorse"):
                        app_status(binary, env, "--action", action)
                        wait_for(binary, env, f"待机时播放 {action} 和对应字幕",
                                 lambda s: s.get("pose") == action and matched_voice(s, action))
                        wait_for(binary, env, f"{action} 结束后回到待机", lambda s: s.get("pose") == "idle")
                    wait_for(binary, env, "空闲时完成散步", lambda s: s.get("completedSwims", 0) > 0, timeout=32)
                    fcntl.flock(lock, fcntl.LOCK_UN)

                app_status(binary, env, "--action", "greeting")
                wait_for(binary, env, "隐藏前已启动录音", lambda s: matched_voice(s, "greeting") and s["voice"]["playing"])
                app_status(binary, env, "--hide")
                wait_for(binary, env, "隐藏窗口且保留菜单进程",
                         lambda s: s.get("running") is True and s.get("visible") is False and s.get("hidden") and
                         s["voice"]["event"] is None and not s["voice"]["playing"] and s.get("caption") is None)
                app_status(binary, env, "--show")
                wait_for(binary, env, "显示大肥鱼", lambda s: s.get("visible") is True)
                app_status(binary, env, "--quit")
                assert process.wait(timeout=4) == 0
                assert app_status(binary, env, "--status")["running"] is False
                print("干净退出", flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
    return {"voices": records, "audio": "real player at volume zero", "oldSkinGreetingVerified": True,
            "quickReplacementVerified": True, "hideInterruptedAudio": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="在独立配置中验证大肥鱼桌宠，需要当前 macOS 图形会话")
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = smoke(args.bundle.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2))
