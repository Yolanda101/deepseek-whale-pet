#!/usr/bin/env python3
"""Build the public, self-contained Desktop Pet Studio app on Apple Silicon."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
from dialogue_assets import install as install_dialogue

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent
IDENTITY = "com.local.desktop-pet-studio"
VERSION = "1.3"


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def build(output):
    if platform.machine() != "arm64":
        raise RuntimeError("The current release targets Apple Silicon Macs.")
    output = output.expanduser().absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.is_symlink():
        raise RuntimeError("Refusing to replace a symbolic-link output.")
    if output.exists():
        info = output / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != IDENTITY:
            raise RuntimeError("The output belongs to a different application.")
    with tempfile.TemporaryDirectory(prefix=".desktop-pet-studio-build-", dir=output.parent) as staging, \
            tempfile.TemporaryDirectory(prefix="desktop-pet-studio-swift-") as cache:
        cache = str(Path(cache).resolve())
        temporary = Path(staging)
        app = temporary / output.name
        contents = app / "Contents"
        resources = contents / "Resources"
        engines = resources / "Engines"
        engines.mkdir(parents=True)
        install_dialogue(resources)
        dragon = engines / "GPT白龙.app"
        whale = engines / "DeepSeek大肥鱼.app"
        run(sys.executable, "-B", "companion/dragon/build.py", "--output", dragon,
            "--module-cache-path", cache)
        run(sys.executable, "-B", "app/build.py", "--output", whale,
            "--module-cache-path", cache)
        info_file = whale / "Contents/Info.plist"
        info = plistlib.loads(info_file.read_bytes())
        info["CFBundleIdentifier"] = IDENTITY + ".whale-engine"
        info["LSUIElement"] = True
        info_file.write_bytes(plistlib.dumps(info))
        run("/usr/bin/codesign", "--force", "--sign", "-", whale)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", whale)
        idle = sorted((ROOT / "assets/figurine/frames/idle").glob("*.png"))[0]
        shutil.copyfile(idle, resources / "Whale.png")
        shutil.copyfile(whale / "Contents/Resources/Whale.icns", resources / "Companion.icns")
        shutil.copytree(ROOT / "licenses", resources / "licenses")
        for name in ("LICENSE", "NOTICE.md"):
            shutil.copyfile(ROOT / name, resources / name)
        (resources / "使用说明.txt").write_text(
            "在窗口选择伙伴并点召唤。白龙和大肥鱼各最多一只，可以同时出现。\n"
            "收回会结束对应进程并删除该实例临时数据，不产生累积编号。\n"
            "两种角色可分别调整大小80至224，也可同步Codex大小。\n"
            "一起玩提供六种互动、十二套三轮对白；工作或用户操作时会让位。\n"
            "两种角色都有两列三行分页表情框，白龙使用青春御姐录音。\n"
            "关闭窗口后伙伴继续运行；点击Dock图标重新打开窗口。退出应用会收回伙伴。\n"
            "公开版附带大肥鱼全部动画和活泼调皮配音。白龙引擎和语音已包含，\n"
            "白龙美术素材需自行导入有权使用的原有应用或Frames素材目录。\n"
            "导入只保存动画图片，不读取原应用的账号、偏好或程序。\n"
            "完整署名和许可见NOTICE.md及licenses目录。\n", encoding="utf-8")
        binary = contents / "MacOS/DesktopPetStudio"
        binary.parent.mkdir()
        run("/usr/bin/swiftc", "-O", "-target", "arm64-apple-macos13.0",
            "-module-cache-path", cache, "companion/main.swift", "companion/Interactions.swift", "app/shared/NativePetSize.swift", "-o", binary)
        plist = dict(
            CFBundleIdentifier=IDENTITY, CFBundleDisplayName="桌宠伙伴", CFBundleName="桌宠伙伴",
            CFBundleExecutable=binary.name, CFBundleIconFile="Companion",
            CFBundleInfoDictionaryVersion="6.0", CFBundlePackageType="APPL",
            CFBundleShortVersionString=VERSION, CFBundleVersion="4", CFBundleDevelopmentRegion="zh_CN",
            LSMinimumSystemVersion="13.0", NSHighResolutionCapable=True, NSPrincipalClass="NSApplication",
            NSHumanReadableCopyright="Desktop Pet Studio contributors. See NOTICE.md for asset credits.",
        )
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
        sources = sorted({*SOURCE.glob("*.swift"), *SOURCE.glob("*.py"),
                          *(SOURCE / "dragon").glob("*.swift"), *(SOURCE / "dragon").glob("*.py"),
                          *(ROOT / "app").glob("*.swift"), *(ROOT / "app/shared").glob("*.swift")})
        metadata = {
            "name": "桌宠伙伴", "version": VERSION, "localOnly": False,
            "dragonArtworkIncluded": False, "dialogueScripts": 12,
            "sources": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sources},
        }
        (resources / "BUILD-INFO.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
        run("/usr/bin/codesign", "--force", "--sign", "-", app)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        run(binary, "--help")
        previous = temporary / "previous.app"
        if output.exists():
            output.rename(previous)
        try:
            app.rename(output)
        except BaseException:
            if previous.exists():
                previous.rename(output)
            raise
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/桌宠伙伴.app")
    build(parser.parse_args().output)
