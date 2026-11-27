"""Install or update the whale app and register its per-user Codex expression helper."""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


SOURCE = Path(__file__).resolve().parent.parent / "dist/DeepSeek大肥鱼桌宠.app"
DEST = Path.home() / "Applications" / SOURCE.name
LABEL = "com.local.deepseek.whalepet.expressions"
DOMAIN = f"gui/{os.getuid()}"
JOB = DOMAIN + "/" + LABEL
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
HELPER = DEST / "Contents/Helpers/CodexWhaleExpressions.app/Contents/MacOS/CodexWhaleExpressions"
BINARY = DEST / "Contents/MacOS/DeepSeekWhale"


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, timeout=35, check=check)


def exchange(a, b):
    fn = ctypes.CDLL(None, use_errno=True).renamex_np
    fn.argtypes = ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint
    if fn(os.fsencode(a), os.fsencode(b), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def write_agent(data):
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=PLIST.parent, prefix=".whale-", delete=False) as f:
        temporary = Path(f.name)
        f.write(data)
    try:
        temporary.chmod(0o644)
        os.replace(temporary, PLIST)
    finally:
        temporary.unlink(missing_ok=True)


def status(option):
    return json.loads(run(BINARY, option).stdout)


def wait(option, expected, timeout=18):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        report = status(option)
        if expected(report):
            return report
        time.sleep(.2)
    raise RuntimeError(f"未能确认桌宠的运行状态 {report}")


def stop_pet():
    if status("--status").get("running"):
        run(BINARY, "--quit")
        wait("--status", lambda r: not r["running"])


def verify_bundle(bundle):
    info = bundle / "Contents/Info.plist"
    if (bundle.is_symlink() or not info.is_file() or
            plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "com.local.deepseek.whalepet"):
        raise ValueError(f"此目录不是大肥鱼桌宠 {bundle}")


def install(dry_run=False):
    verify_bundle(SOURCE)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", SOURCE)
    if dry_run:
        print(f"桌宠：{DEST}\nCodex 表情助手的登录项：{PLIST}")
        return
    DEST.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(DEST.parent, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        install_locked()
    finally:
        os.close(lock)


def install_locked():
    existing = DEST.exists()
    if existing or DEST.is_symlink():
        verify_bundle(DEST)
    running_before = existing and status("--status")["running"]
    version = run(SOURCE / "Contents/MacOS/DeepSeekWhale", "--version").stdout.strip()
    if PLIST.is_symlink():
        raise ValueError(f"登录项是符号链接 {PLIST}")
    old_plist = PLIST.read_bytes() if PLIST.exists() else None
    if old_plist:
        previous = plistlib.loads(old_plist)
        if previous.get("Label") != LABEL or previous.get("ProgramArguments") != [str(HELPER)]:
            raise ValueError(f"登录项指向了其他程序 {PLIST}")
    old_loaded = run("/bin/launchctl", "print", JOB, check=False).returncode == 0
    if old_loaded and not old_plist:
        raise ValueError(f"已有其他服务使用同一标识 {LABEL}")
    registration = plistlib.dumps({
        "Label": LABEL, "ProgramArguments": [str(HELPER)], "RunAtLoad": True,
        "KeepAlive": {"Crashed": True}, "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
    })
    with tempfile.TemporaryDirectory(prefix=".whale-update-", dir=DEST.parent) as stage:
        copy = Path(stage) / DEST.name
        run("/usr/bin/ditto", SOURCE, copy)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", copy)
        swapped = changed_plist = loaded = unloaded_previous = False
        try:
            if old_loaded:
                run("/bin/launchctl", "bootout", JOB)
                unloaded_previous = True
                if existing:
                    wait("--native-status", lambda r: not r["running"])
            if running_before:
                stop_pet()
            if existing:
                exchange(copy, DEST)
            else:
                copy.rename(DEST)
            swapped = True
            write_agent(registration)
            changed_plist = True
            run("/bin/launchctl", "bootstrap", DOMAIN, PLIST)
            loaded = True
            native = wait("--native-status", lambda r: r["running"] and r.get("pid") and not r.get("playbackError"))
            if running_before or not existing:
                run("/usr/bin/open", "-g", DEST)
                wait("--status", lambda r: r["running"] and r.get("version") == version)
            print(f"大肥鱼 {version}，Codex 表情服务进程 {native['pid']}")
        except BaseException:
            if loaded:
                run("/bin/launchctl", "bootout", JOB)
            if swapped:
                stop_pet()
                if existing:
                    exchange(copy, DEST)
                else:
                    DEST.rename(copy)
            if changed_plist:
                if old_plist is None:
                    PLIST.unlink()
                else:
                    write_agent(old_plist)
            if unloaded_previous:
                run("/bin/launchctl", "bootstrap", DOMAIN, PLIST)
            if running_before and not status("--status")["running"]:
                run("/usr/bin/open", "-g", DEST)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="安装大肥鱼和当前用户的原生表情助手，升级时保留偏好")
    parser.add_argument("--dry-run", action="store_true", help="检查应用签名并显示安装位置")
    install(dry_run=parser.parse_args().dry_run)
