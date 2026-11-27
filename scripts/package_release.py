"""Package the built macOS pet without local filesystem metadata."""

import hashlib
from pathlib import Path
import plistlib
import stat
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "dist/DeepSeek大肥鱼桌宠.app"
OUTPUT = ROOT / "releases"


def main():
    subprocess.run(["codesign", "--verify", "--deep", "--strict", BUNDLE], check=True)
    info = plistlib.loads((BUNDLE / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    binary = BUNDLE / "Contents/MacOS" / info["CFBundleExecutable"]
    architecture = (
        subprocess.run(
            ["lipo", "-archs", binary], check=True, text=True, capture_output=True
        )
        .stdout.strip()
        .replace(" ", "-")
    )
    name = f"DeepSeekWhalePet-v{version}-macos-{architecture}"
    OUTPUT.mkdir(exist_ok=True)
    destination = OUTPUT / (name + ".zip")

    files = {}
    for directory in ("dist", "codex-pet", "licenses"):
        for path in (ROOT / directory).rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Unsupported symbolic link {path.relative_to(ROOT)}")
            if path.is_file() and not any(
                part.startswith(".") or part == "__pycache__"
                for part in path.relative_to(ROOT).parts
            ):
                files[str(path.relative_to(ROOT))] = path
    for relative in (
        "app/install.py",
        "LICENSE",
        "NOTICE.md",
        "assets/素材署名.md",
        "assets/voice/production/配音来源.md",
    ):
        files[relative] = ROOT / relative

    instructions = (
        f"DeepSeek 大肥鱼桌宠 {version}\n\n"
        "适用于 Apple Silicon Mac，macOS 13 及以上。\n"
        "打开 dist/DeepSeek大肥鱼桌宠.app 即可使用独立桌宠。\n\n"
        "要安装到当前用户 Applications 并注册 Codex 表情助手，\n"
        "在本目录运行 python3 app/install.py，需要 Python 3。\n"
        "可先用 python3 app/install.py --dry-run 检查安装位置。\n\n"
        "将 codex-pet/deepseek-q-whale 文件夹复制到 ~/.codex/pets/，\n"
        "再在 Codex 的宠物设置中选择 DeepSeek 大肥鱼 · 手办版。\n"
        "自定义 CODEX_HOME 的用户请复制到其 pets 子目录。\n\n"
        "鼠标悬停后每页显示两列三行表情，可左右翻页并点击点播。\n"
        "12 个表情和任务完成提醒都使用大肥鱼的原创普通话配音，可以离线播放。\n"
        "菜单栏中可以调整大小、开关语音、开启任务完成提醒。\n\n"
        "应用采用本机临时签名，尚未经过 Apple 公证。\n"
        "素材署名和许可见 NOTICE.md、LICENSE 及 licenses/ 目录。\n"
    ).encode()

    def add(archive, relative, data, executable=False):
        entry = zipfile.ZipInfo(name + "/" + relative, (2026, 11, 27, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, data)

    with zipfile.ZipFile(
        destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as archive:
        for relative, path in sorted(files.items()):
            add(archive, relative, path.read_bytes(), bool(path.stat().st_mode & 0o111))
        add(archive, "安装说明.txt", instructions)

    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    (OUTPUT / "SHA256SUMS").write_text(f"{digest}  {destination.name}\n")
    print(destination)
    print(digest)


if __name__ == "__main__":
    main()
