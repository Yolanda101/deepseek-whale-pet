#!/usr/bin/env python3
"""Package the public Apple Silicon Desktop Pet Studio release."""

import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
BUNDLE = Path("dist/桌宠伙伴.app")
RELEASES = ROOT / "releases"
VERSION = "1.3"
IDENTITY = "com.local.desktop-pet-studio"
NAME = f"DesktopPetStudio-companion-v{VERSION}-macos-arm64"
SUMS = f"DesktopPetStudio-companion-v{VERSION}-SHA256SUMS.txt"
STAMP = (2026, 11, 28, 0, 0, 0)
DRAGON = ("Contents", "Resources", "Engines", "GPT白龙.app")
EXCLUDED_NAMES = {
    "__macosx", "__pycache__", "cache", "caches", "logs", "module-cache", "modulecache.noindex", "swift-cache",
}
EXCLUDED_SUFFIXES = {".cache", ".log", ".pyc", ".pyo"}
IMAGE_SUFFIXES = {".avif", ".gif", ".heic", ".icns", ".jpeg", ".jpg", ".png", ".svg", ".tiff", ".webp"}
COMPANION_FILES = (
    "companion/install.py",
    "codex-pet/deepseek-q-whale/pet.json",
    "codex-pet/deepseek-q-whale/spritesheet.webp",
    "codex-pet/deepseek-q-whale/使用说明和素材署名.md",
    "codex-pet/deepseek-q-whale/LICENSE",
    "licenses/Character-LICENSE.txt",
    "licenses/Code-MIT.txt",
    "LICENSE",
    "NOTICE.md",
    "assets/素材署名.md",
    "assets/voice/production/配音来源.md",
    "assets/dragon/NOTICE.md",
    "assets/dragon/Care/greetings.json",
    "assets/dragon/Voice/语音来源.md",
    "assets/dragon/Voice/manifest.json",
    "assets/dragon/Voice/verified.json",
    "assets/dialogue/语音来源.md",
)

INSTRUCTIONS = f"""桌宠伙伴 {VERSION}

适用于 Apple Silicon Mac，macOS 13 及以上。解压后打开 dist/桌宠伙伴.app。
运行成品无需 Python。应用采用临时签名，尚未经过 Apple 公证。

安装到当前用户的 Applications 并设置登录启动，需要 Python 3。
在解压后的目录运行 python3 companion/install.py --dry-run 可预览操作。
运行 python3 companion/install.py 执行安装。
首次启用 Codex 大肥鱼表情助手时，在安装命令后加 --native-helper。
更新现有桌宠伙伴时使用 python3 companion/install.py --update-only。

六种互动支持十二套三轮对白，白龙青春御姐与大肥鱼活泼调皮轮流回应。
两种角色都有两列三行的分页表情框，尺寸可分别调整80至224或同步Codex大小。
大肥鱼可直接召唤。公开包附带白龙引擎和语音，白龙画面由你在本机导入。
点击白龙卡片的「导入白龙素材」，选择你有权使用的原有白龙应用或含 Frames 的素材目录。
导入只保存所需动画图片，不读取原应用的账号、配置或程序。

使用 Codex 外观时，把 codex-pet/deepseek-q-whale 复制到 ~/.codex/pets/，
再在 Codex 的宠物设置中选择「DeepSeek 大肥鱼 · 手办版」。
自定义 CODEX_HOME 时请复制到其 pets 子目录。

素材署名和许可见 NOTICE.md、LICENSE 及 licenses/ 目录。
"""


def require_source(relative, expected_type):
    path = ROOT
    for part in relative.parts[:-1]:
        path /= part
        if not stat.S_ISDIR(path.lstat().st_mode):
            raise ValueError(f"Expected a regular directory: {path.relative_to(ROOT)}")
    path /= relative.name
    if not expected_type(path.lstat().st_mode):
        raise ValueError(f"Unexpected file type: {relative}")
    return path


def bundle_files(directory):
    for path in sorted(directory.iterdir()):
        name = path.name.casefold()
        suffix = path.suffix.lower()
        if name.startswith(".") or name in EXCLUDED_NAMES or suffix in EXCLUDED_SUFFIXES:
            continue
        relative = path.relative_to(ROOT / BUNDLE)
        in_dragon = relative.parts[:len(DRAGON)] == DRAGON
        if name in {"dragon.png", "dragon.icns", "dragonartwork"} or (
            in_dragon and (name == "frames" or suffix in IMAGE_SUFFIXES)
        ):
            raise ValueError(f"Private dragon artwork found in the bundle: {relative}")
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            yield from bundle_files(path)
        elif stat.S_ISREG(mode):
            yield path
        else:
            raise ValueError(f"Unsupported bundle entry: {relative}")


def verify_signature(bundle):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", bundle], check=True)


def validate_bundle(bundle):
    info = plistlib.loads(require_source(BUNDLE / "Contents/Info.plist", stat.S_ISREG).read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString")) != (IDENTITY, VERSION):
        raise ValueError("Unexpected companion bundle identifier or version.")
    if info.get("CFBundleExecutable") != "DesktopPetStudio":
        raise ValueError("Unexpected companion executable.")
    metadata = require_source(BUNDLE / "Contents/Resources/BUILD-INFO.json", stat.S_ISREG)
    build = json.loads(metadata.read_bytes())
    if build.get("localOnly") is not False or build.get("dragonArtworkIncluded") is not False:
        raise ValueError("Expected a public companion build without dragon artwork.")
    binary = require_source(BUNDLE / "Contents/MacOS/DesktopPetStudio", stat.S_ISREG)
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", binary], text=True).strip()
    if architecture != "arm64":
        raise ValueError(f"Expected arm64, found {architecture}.")
    verify_signature(bundle)


def zip_entry(relative, executable=False):
    entry = zipfile.ZipInfo(f"{NAME}/{relative}", STAMP)
    entry.create_system = 3
    entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    entry.compress_type = zipfile.ZIP_DEFLATED
    return entry


def write_archive(destination, files):
    with zipfile.ZipFile(destination, "w") as archive:
        for path in sorted(files, key=lambda path: path.relative_to(ROOT).as_posix()):
            entry = zip_entry(path.relative_to(ROOT).as_posix(), path.stat().st_mode & 0o111)
            archive.writestr(entry, path.read_bytes(), compresslevel=6)
        archive.writestr(zip_entry("安装说明.txt"), INSTRUCTIONS.encode("utf-8"), compresslevel=6)


def verify_archived_bundle(archive_path, directory):
    prefix = f"{NAME}/{BUNDLE.as_posix()}/"
    with zipfile.ZipFile(archive_path) as archive:
        for entry in archive.infolist():
            if entry.filename.startswith(prefix):
                path = Path(archive.extract(entry, directory))
                path.chmod(stat.S_IMODE(entry.external_attr >> 16))
    verify_signature(directory / NAME / BUNDLE)


def main():
    bundle = require_source(BUNDLE, stat.S_ISDIR)
    files = list(bundle_files(bundle))
    files.extend(require_source(Path(relative), stat.S_ISREG) for relative in COMPANION_FILES)
    validate_bundle(bundle)
    RELEASES.mkdir(exist_ok=True)
    if RELEASES.is_symlink():
        raise ValueError("The release directory must not be a symbolic link.")
    with tempfile.TemporaryDirectory(prefix=".companion-package-", dir=RELEASES) as staging:
        stage = Path(staging)
        archive = stage / f"{NAME}.zip"
        write_archive(archive, files)
        verify_archived_bundle(archive, stage / "verify")
        digest = hashlib.sha256()
        with archive.open("rb") as data:
            for chunk in iter(lambda: data.read(1024 * 1024), b""):
                digest.update(chunk)
        checksum = stage / SUMS
        checksum.write_text(f"{digest.hexdigest()}  {archive.name}\n", encoding="utf-8")
        archive.replace(RELEASES / archive.name)
        checksum.replace(RELEASES / checksum.name)
    print(RELEASES / archive.name)
    print(digest.hexdigest())


if __name__ == "__main__":
    main()
