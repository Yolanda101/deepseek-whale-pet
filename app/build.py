#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent
ASSETS = ROOT / "assets"
SHARED = SOURCE / "shared"
OUTPUT = ROOT / "dist" / "DeepSeek大肥鱼桌宠.app"
BUNDLE_ID = "com.local.deepseek.whalepet"
BASE_ACTIONS = ("greeting", "dance", "playful", "feeding")
REQUIRED = ("idle", "work", "walkLeft", "walkRight", *BASE_ACTIONS)
FIGURINE_ACTIONS = ("tailwag", "angry", "dizzy", "hungry", "outing", "crying", "rice", "remorse")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def copy_skin(source, target):
    frames = source / "frames" if (source / "frames").is_dir() else source
    for state in REQUIRED:
        if len(list((frames / state).glob("*.png"))) < 2:
            raise RuntimeError(f"动画缺少帧文件 {frames / state}")
    manifest = frames / "manifest.json"
    if not manifest.is_file():
        manifest = source / "manifest.json"
    if not manifest.is_file():
        raise RuntimeError(f"动画尚未发布清单 {source}")

    target.mkdir(parents=True)
    shutil.copy2(manifest, target / "manifest.json")
    for state in (*REQUIRED, "drag", *FIGURINE_ACTIONS):
        source_dir = frames / state
        if not source_dir.is_dir():
            continue
        dest_dir = target / state
        dest_dir.mkdir()
        for file in source_dir.glob("*.png"):
            shutil.copy2(file, dest_dir / file.name)


def copy_voice(source, destination):
    manifest_file = source / "manifest.json"
    manifest = json.loads(manifest_file.read_bytes())
    required = {*BASE_ACTIONS, *FIGURINE_ACTIONS, "task_done"}
    lines = manifest.get("lines", {})
    if manifest.get("version") != 1 or set(lines) != required:
        raise ValueError("语音清单必须覆盖所有表情和任务完成提醒")
    destination.mkdir()
    used = set()
    for event, variants in lines.items():
        if not isinstance(variants, list) or not variants:
            raise ValueError(f"缺少台词 {event}")
        for line in variants:
            name = line["file"]
            if Path(name).name != name or name.startswith(".") or not name.endswith(".wav") or name in used:
                raise ValueError(f"无效或重复的语音文件 {name}")
            used.add(name)
            shutil.copy2(source / name, destination / name)
    shutil.copy2(manifest_file, destination / manifest_file.name)


def make_icon(frame, resources, temp_dir):
    png = temp_dir / "icon.png"
    sections = []
    for side, subtype in [(16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"),
                          (256, b"ic08"), (512, b"ic09"), (1024, b"ic10")]:
        pixels = str(side)
        run("/usr/bin/sips", "-z", pixels, pixels, str(frame), "--out", str(png),
            stdout=subprocess.DEVNULL)
        data = png.read_bytes()
        sections.append(struct.pack(">4sI", subtype, len(data) + 8) + data)
    body = b"".join(sections)
    (resources / "Whale.icns").write_bytes(struct.pack(">4sI", b"icns", len(body) + 8) + body)


def native_geometry(resources):
    native = ROOT / "codex-pet"
    sheet = native / "deepseek-q-whale/spritesheet.webp"
    approved = json.loads((native / "verified.json").read_bytes())["webpSHA256"]
    if hashlib.sha256(sheet.read_bytes()).hexdigest() != approved:
        raise RuntimeError("原生图集有变更，需要先核对角色的位置和比例")
    layout = json.loads((native / "layout.json").read_bytes())
    transform = layout["transform"]
    x, y = transform["pixelOffset"]
    w, h = layout["cell"]
    neutral = layout["neutral"]
    first = layout["states"]["idle"]["cells"][0]
    idle = (ASSETS / "figurine/frames" / first["source"]).read_bytes()
    if neutral["desktopAndCloud"] != first["source"] or hashlib.sha256(idle).hexdigest() != first["sourceSHA256"]:
        raise RuntimeError("原生中立姿势与完整动作的原画不同")
    size = tuple(round(side * transform["scale"]) for side in struct.unpack(">II", idle[16:24]))
    run("/usr/bin/sips", "-s", "format", "png", "--cropToHeightWidth", str(h), str(w),
        "--cropOffset", str(neutral["row"] * h), str(neutral["column"] * w),
        sheet, "--out", resources / "NativeMask.png", stdout=subprocess.DEVNULL)
    geometry = dict(tileWidth=w, tileHeight=h, imageWidth=size[0], imageHeight=size[1], offsetX=x, offsetY=y)
    (resources / "NativeFrames.json").write_text(json.dumps(geometry))


def build(destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        prior = destination / "Contents" / "Info.plist"
        if not prior.is_file() or plistlib.loads(prior.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID:
            raise RuntimeError(f"该路径已有其他应用 {destination}")

    with tempfile.TemporaryDirectory(prefix=".deepseek-whale-build-", dir=destination.parent) as temp:
        temp_dir = Path(temp)
        bundle = temp_dir / destination.name
        contents = bundle / "Contents"
        resources = contents / "Resources"
        binary = contents / "MacOS" / "DeepSeekWhale"
        binary.parent.mkdir(parents=True)
        resources.mkdir()

        plist = dict(
            CFBundleIdentifier=BUNDLE_ID,
            CFBundleDisplayName="DeepSeek 大肥鱼",
            CFBundleName="大肥鱼",
            CFBundleExecutable=binary.name,
            CFBundleIconFile="Whale",
            CFBundleInfoDictionaryVersion="6.0",
            CFBundlePackageType="APPL",
            CFBundleShortVersionString="1.9",
            CFBundleVersion="12",
            CFBundleDevelopmentRegion="zh_CN",
            LSMinimumSystemVersion="13.0",
            LSUIElement=True,
            NSHighResolutionCapable=True,
            NSPrincipalClass="NSApplication",
        )
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist))

        motion = ASSETS / "motion"
        frames = resources / "Frames"
        copy_skin(motion, frames / "original")
        artwork = frames / "figurine"
        copy_skin(ASSETS / "figurine", artwork)
        metadata = json.loads((artwork / "manifest.json").read_bytes())
        for state in (*REQUIRED, *FIGURINE_ACTIONS):
            info = metadata["states"][state]
            count = len(list((artwork / state).glob("*.png")))
            times = info["frameDurationsMs"]
            if info["frameCount"] != count or len(times) != count or any(t <= 0 for t in times):
                raise RuntimeError(f"手办动作帧数或时长有误 {state}")
        idle_frames = sorted((artwork / "idle").glob("*.png"))
        make_icon(idle_frames[0], resources, temp_dir)
        native_geometry(resources)

        expressions = resources / "Expressions"
        expressions.mkdir()
        for expression in (*BASE_ACTIONS, *FIGURINE_ACTIONS):
            icon = ASSETS / "figurine" / "expressions" / (expression + ".png")
            shutil.copy2(icon, expressions / icon.name)
        copy_voice(ASSETS / "voice", resources / "Voice")
        for path, name in [(ASSETS / "素材署名.md", "素材署名.md"),
                           (ROOT / "licenses/Character-LICENSE.txt", "Character-LICENSE.txt"),
                           (ROOT / "licenses/Code-MIT.txt", "Code-MIT.txt"),
                           (ROOT / "NOTICE.md", "NOTICE.md"),
                           (motion / "ASSET-NOTICE.md", "Animation-NOTICE.md")]:
            shutil.copy2(path, resources / name)

        cache = Path(tempfile.gettempdir()) / "deepseek-whale-swift-cache"
        compiler = ["/usr/bin/swiftc", "-O", "-target", f"{platform.machine()}-apple-macos13.0", "-module-cache-path", str(cache)]
        common = [SOURCE / name for name in ("Animation.swift", "WhaleSpeech.swift", "ExpressionPanel.swift", "Storage.swift", "WhaleWindowOverlap.swift")]
        common += [SHARED / name for name in ("ActivityMonitor.swift", "NativePetSize.swift")]
        run(*compiler, *common, SOURCE / "main.swift", SOURCE / "PetStage.swift", SHARED / "PetSizeControl.swift",
            "-lsqlite3", "-o", str(binary))
        helper = contents / "Helpers" / "CodexWhaleExpressions.app"
        helper_binary = helper / "Contents/MacOS/CodexWhaleExpressions"
        helper_binary.parent.mkdir(parents=True)
        helper_plist = {k: v for k, v in plist.items() if k != "CFBundleIconFile"}
        helper_plist.update(CFBundleName="Codex 大肥鱼表情", CFBundleDisplayName="Codex 大肥鱼表情",
                            CFBundleExecutable=helper_binary.name, CFBundleIdentifier=BUNDLE_ID + ".expressions")
        (helper / "Contents/Info.plist").write_bytes(plistlib.dumps(helper_plist))
        run(*compiler, *common, SOURCE / "NativeExpressionService.swift", SOURCE / "NativeWhaleInteraction.swift",
            SOURCE / "NativeWhaleTarget.swift", SHARED / "NativePetLocator.swift",
            "-lsqlite3", "-o", helper_binary)
        run("/usr/bin/codesign", "--force", "--sign", "-", str(helper))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(bundle))
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", str(bundle))
        verification = run(str(binary), "--verify-assets", text=True, stdout=subprocess.PIPE)
        if "figurine" not in json.loads(verification.stdout):
            raise RuntimeError("Q 版手办动画未通过检查")
        print(verification.stdout.strip())

        backup = temp_dir / "previous.app"
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(bundle, destination)
        except OSError:
            if backup.exists():
                os.replace(backup, destination)
            raise
    print(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="构建大肥鱼 macOS 桌宠")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    build(args.output.resolve())
