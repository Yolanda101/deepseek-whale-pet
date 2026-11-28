#!/usr/bin/env python3
"""Verify GPT White Dragon's packaged expressions in an isolated macOS graphics session."""

import argparse
from datetime import date, datetime, timezone
import hashlib
from io import BytesIO
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid
import wave


VOICE = ("greeting", "dance", "playful", "task_done", "star_catch", "star_dance", "cheer", "shy", "sleepy")
CARE = ("hello", "bailong", "check_in", "good_thing", "water", "stretch", "smile", "take_it_easy")
SOCIAL = ("highfive", "nuzzle", "duet", "beckon", "starpass", "chase")
PAGES = (
    (("greeting", "打招呼"), ("dance", "跳舞"), ("playful", "撒娇"), ("cheer", "加油"),
     ("shy", "害羞"), ("sleepy", "困困")),
    (("water", "喝水"), ("stretch", "伸懒腰")),
)
AUDIO_TOLERANCE = 0.035


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_voice_pack(resources):
    manifest = json.loads((resources / "Voice/manifest.json").read_text(encoding="utf-8"))
    approval = json.loads((resources / "Voice/verified.json").read_text(encoding="utf-8"))
    lines = manifest["lines"]
    hashes = approval["files"]
    group_paths = {"Voice": resources / "Voice", "Care": resources / "Care", "Social": resources / "Voice/Social"}
    keys = [(group, name) for group, names in (("Voice", VOICE), ("Care", CARE), ("Social", SOCIAL)) for name in names]
    require(set(lines) == {f"{group}/{name}" for group, name in keys}, "包内配音清单的 23 个动作不完整")
    require(approval["complete"] is True and approval["count"] == len(keys) and
            set(hashes) == {f"{key}.wav" for key in lines}, "包内配音验收清单不完整")
    durations = {}
    for group, name in keys:
        key = f"{group}/{name}"
        require(isinstance(lines[key], str) and bool(lines[key].strip()), f"台词为空 {key}")
        audio = (group_paths[group] / f"{name}.wav").read_bytes()
        require(hashlib.sha256(audio).hexdigest() == hashes[f"{key}.wav"], f"包内录音与定稿不匹配 {key}")
        with wave.open(BytesIO(audio), "rb") as recording:
            require((recording.getframerate(), recording.getnchannels(), recording.getsampwidth()) == (24000, 1, 2),
                    f"录音格式不符合清单 {key}")
            frame_count = recording.getnframes()
            require(frame_count > 0 and len(recording.readframes(frame_count)) == frame_count * 2,
                    f"录音数据不全 {key}")
            durations[key] = frame_count / recording.getframerate()
    return lines, durations


def check_page(panel, page):
    require(panel["visible"] and panel["page"] == page and panel["pageCount"] == len(PAGES),
            f"表情分页状态错误 第 {page} 页")
    items = panel["items"]
    require([(item["id"], item["title"]) for item in items] == list(PAGES[page - 1]),
            f"表情按钮顺序或标签错误 第 {page} 页")
    require((panel["previous"] is not None, panel["next"] is not None) == (page > 1, page < len(PAGES)),
            f"翻页按钮状态错误 第 {page} 页")
    rows = list(zip(items[::2], items[1::2]))
    require(len(rows) == (3 if page == 1 else 1), f"表情行数错误 第 {page} 页")
    frame = panel["frame"]
    for item in items:
        require(item["width"] > 0 and item["height"] > 0 and
                frame["x"] <= item["x"] and item["x"] + item["width"] <= frame["x"] + frame["width"] and
                frame["y"] <= item["y"] and item["y"] + item["height"] <= frame["y"] + frame["height"],
                f"表情按钮超出面板 {item['id']}")
    for index, (left, right) in enumerate(rows):
        require(left["x"] + left["width"] <= right["x"] and
                math.isclose(left["y"], right["y"], abs_tol=0.5) and
                math.isclose(left["x"], rows[0][0]["x"], abs_tol=0.5) and
                math.isclose(right["x"], rows[0][1]["x"], abs_tol=0.5), f"表情未对齐两列 第 {page} 页第 {index + 1} 行")
        if index:
            require(left["y"] + left["height"] <= rows[index - 1][0]["y"], f"表情行有重叠 第 {page} 页")


class Dragon:
    def __init__(self, binary, directory, process, environment, instance_id):
        self.binary = binary
        self.directory = directory
        self.process = process
        self.environment = environment
        self.instance_id = instance_id
        self.initial_size = None

    def snapshot(self):
        path = self.directory / "status.json"
        return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}

    def request(self, *arguments, expected=0):
        reply = subprocess.run([str(self.binary), *arguments], env=self.environment,
                               capture_output=True, text=True, encoding="utf-8", timeout=8)
        require(reply.returncode == expected,
                f"{arguments[0]} 返回 {reply.returncode}，预期 {expected}。{reply.stderr.strip()}")
        if expected:
            return reply.stderr
        report = json.loads(reply.stdout)
        require(report["pid"] == self.process.pid and report["instanceID"].lower() == self.instance_id,
                "指令响应来自其他实例")
        if self.initial_size is not None:
            require((report["petWidth"], report["sizeSetting"], report["size"]) == self.initial_size,
                    "表情或互动修改了角色大小")
            require(report["muted"] is False and report["roaming"] is False and report["social"] is False,
                    "表情或互动修改了测试偏好")
        return report

    def wait(self, description, predicate, timeout=10, fresh=True):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(self.process.poll() is None, f"等待时白龙进程退出 {description}")
            report = self.request("--status") if fresh else self.snapshot()
            if predicate(report):
                return report
            time.sleep(0.07)
        raise RuntimeError(f"未观察到预期状态 {description}")


def start_social_scene(dragon, state):
    position, size, screen = (state[key] for key in ("position", "size", "screen"))
    x = position["x"] + size["width"] / 2
    y = position["y"] + size["height"] / 2
    width = 100
    other_side = screen["x"] + screen["width"] * (0.25 if x > screen["x"] + screen["width"] / 2 else 0.75)
    cue = {
        "id": str(uuid.uuid4()),
        "behavior": "starpass",
        "role": "initiator",
        "startAt": time.monotonic() + 1,
        "duration": 8,
        "destination": {"x": x, "y": y},
        "peer": {"x": other_side - width / 2, "y": y - 54, "width": width, "height": 108},
    }
    accepted = dragon.request("--interact", json.dumps(cue))
    require((accepted["interaction"] or {}).get("id") == cue["id"], "白龙未接收传星星互动")
    active = dragon.wait("传星星互动进入实际表演",
                         lambda report: (report["interaction"] or {}).get("id") == cue["id"]
                         and report["effectVisible"] and report["lastSpeechSource"] == "recording:starpass")
    unrelated = dragon.request("--cancel-interaction", str(uuid.uuid4()))
    require((unrelated["interaction"] or {}).get("id") == cue["id"], "取消指令影响了其他互动")
    return cue["id"], active["interactionCancelled"]


def verify_expression(dragon, expression, line, expected_duration, cancel_scene=None):
    source = f"recording:{expression}"
    initial = dragon.request("--action", expression)
    require(initial["selectedExpression"] == expression and initial["lastExpression"] == expression,
            f"没有执行表情 {expression}")
    require(initial["messageVisible"] and initial["lastMessage"] == line, f"字幕与配音清单不一致 {expression}")
    require(initial["lastSpeechSource"] == source, f"表情没有采用包内录音 {expression}")
    require(initial["voicePlaying"] is True, f"未观察到录音开始 {expression}")
    duration = initial["voiceDuration"]
    require(duration > 0 and math.isclose(duration, expected_duration, abs_tol=AUDIO_TOLERANCE),
            f"录音时长与包内 WAV 不符 {expression} {duration:.3f}/{expected_duration:.3f}")
    if cancel_scene is not None:
        scene_id, previous_count = cancel_scene
        last_scene = initial["lastInteraction"] or {}
        require(initial["interaction"] is None and
                last_scene.get("id") == scene_id and last_scene.get("phase") == "cancelled" and
                initial["interactionCancelled"] == previous_count + 1 and not initial["effectVisible"],
                "选择表情没有撤掉已开始的双宠互动和特效")

    previous_elapsed = initial["voiceElapsed"]
    require(0 <= previous_elapsed < duration, f"开始时的录音进度异常 {expression}")
    samples = 1
    incomplete_since = None

    def audio_finished(state):
        nonlocal previous_elapsed, samples, incomplete_since
        samples += 1
        require(state["lastSpeechSource"] == source and state["lastMessage"] == line,
                f"录音或字幕在播放期间被替换 {expression}")
        require(state["selectedExpression"] == expression and state["messageVisible"],
                f"表情或字幕先于录音结束 {expression}")
        elapsed = state["voiceElapsed"]
        if state["voicePlaying"] is False:
            if math.isclose(elapsed, duration, abs_tol=AUDIO_TOLERANCE):
                return True
            # The player can stop reporting active a moment before its completion callback saves the final time.
            observed = time.monotonic()
            incomplete_since = observed if incomplete_since is None else incomplete_since
            require(observed - incomplete_since <= 0.35,
                    f"录音提前停止 {expression} {elapsed:.3f}/{duration:.3f}")
            return False
        require(previous_elapsed - AUDIO_TOLERANCE <= elapsed <= duration + AUDIO_TOLERANCE,
                f"录音进度异常 {expression} {previous_elapsed:.3f}→{elapsed:.3f}")
        previous_elapsed = elapsed
        return False

    completed = dragon.wait(f"{expression} 完整播完", audio_finished, timeout=duration + 5)
    dragon.wait(f"{expression} 字幕和特效收尾",
                lambda state: state["selectedExpression"] is None and not state["messageVisible"]
                and not state["effectVisible"] and state["interactionReady"],
                timeout=max(6, len(line) * 0.19 + 3))
    return {"id": expression, "caption": line, "source": source, "wav_duration_seconds": expected_duration,
            "reported_duration_seconds": duration, "played_seconds": completed["voiceElapsed"], "samples": samples}


def verify(bundle):
    contents = bundle / "Contents/Resources/Engines/GPT白龙.app/Contents"
    binary = contents / "MacOS/GPTDragon"
    require(binary.is_file(), f"未找到统一版嵌入的白龙程序 {binary}")
    bundle_version = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
    lines, durations = read_voice_pack(contents / "Resources")

    with tempfile.TemporaryDirectory(prefix="desktop-pet-dragon-expressions-") as folder:
        directory = Path(folder)
        activity = directory / "ActivityFixture"
        activity.mkdir()
        instance_id = str(uuid.uuid4())
        (directory / "preferences.plist").write_bytes(plistlib.dumps({
            "muted": False, "roamingPaused": True, "socialPaused": True, "socialDisabled": True,
            "independentWidth": 146, "greetedDays": [date.today().isoformat()],
        }))
        environment = {
            **os.environ, "DESKTOP_PET_MANAGED": "1", "DESKTOP_PET_INSTANCE_ID": instance_id,
            "DESKTOP_PET_INSTANCE_DIR": str(directory), "DESKTOP_PET_MANAGER_PID": str(os.getpid()),
            "DESKTOP_PET_SPAWN_SLOT": "1", "DESKTOP_PET_HUB_QUIET": "1", "DESKTOP_PET_AUDIO_TEST_SILENT": "1",
            "DESKTOP_PET_ACTIVITY_TEST_HOME": str(activity),
        }
        with (directory / "dragon.log").open("w+", encoding="utf-8") as log:
            process = subprocess.Popen([str(binary)], env=environment, stdout=log, stderr=log)
            dragon = Dragon(binary, directory, process, environment, instance_id)
            try:
                startup = dragon.wait("独立白龙窗口就绪", lambda state: state.get("interactionReady"), fresh=False)
                require(startup.get("pid") == process.pid and startup.get("instanceID", "").lower() == instance_id,
                        "启动状态来自其他实例")
                require(startup.get("visible") and startup.get("taskStateKnown") and not startup.get("menuBarIcon"),
                        "独立白龙没有进入可见受管状态")
                dragon.initial_size = (startup["petWidth"], startup["sizeSetting"], startup["size"])
                first_page = dragon.request("--expression-panel", "show")["expressionPanel"]
                check_page(first_page, 1)
                second_page = dragon.request("--expression-panel", "next")["expressionPanel"]
                check_page(second_page, 2)
                check_page(dragon.request("--expression-panel", "previous")["expressionPanel"], 1)
                require(not dragon.request("--expression-panel", "hide")["expressionPanel"]["visible"],
                        "表情框未关闭")
                require("--action" in dragon.request("--action", "unknown_expression", expected=2),
                        "非法表情没有返回动作参数错误")
                ready = dragon.request("--status")
                require(ready["selectedExpression"] is None and ready["interactionReady"], "非法表情改变了角色状态")
                scene = start_social_scene(dragon, ready)
                expressions = []
                for page in PAGES:
                    for expression, _ in page:
                        path = f"{'Care' if expression in CARE else 'Voice'}/{expression}"
                        expressions.append(verify_expression(dragon, expression, lines[path], durations[path],
                                                             cancel_scene=scene if expression == "greeting" else None))
                dragon.request("--quit")
                require(process.wait(timeout=8) == 0, "测试进程未正常退出")
                return {
                    "ok": True, "bundle": str(bundle), "version": bundle_version, "engine_version": startup["version"],
                    "manifest_recordings": len(lines),
                    "pages": [[item["id"] for item in first_page["items"]], [item["id"] for item in second_page["items"]]],
                    "page_layout": {"columns": 2, "rows_per_page": [3, 1]},
                    "invalid_action_rejected": True, "expression_cancelled_active_social_scene": True,
                    "fixed_width": dragon.initial_size[0], "recordings_played_at_zero_volume": True,
                    "muted_preference": False, "expression_results": expressions, "test_process_exited": True,
                }
            except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                log.seek(0)
                details = log.read()[-2500:].strip()
                raise RuntimeError(f"{error}\n{details}" if details else str(error)) from error
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="整合版桌宠伙伴应用路径")
    parser.add_argument("--report", type=Path, help="将 JSON 验收报告写到指定路径")
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    try:
        report = verify(bundle)
    except (RuntimeError, ValueError, KeyError, OSError, EOFError, wave.Error, subprocess.SubprocessError) as error:
        report = {"ok": False, "bundle": str(bundle), "error": str(error)}
    report["checked_at_utc"] = datetime.now(timezone.utc).isoformat()
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
