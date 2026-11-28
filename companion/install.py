#!/usr/bin/env python3
"""Install or update Desktop Pet Studio with per-user login jobs."""

import argparse
from contextlib import contextmanager
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import fcntl
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HUB = "com.local.desktop-pet-studio"
DRAGON = "com.local.gptdragon.companion"
EXPRESSIONS = "com.local.deepseek.whalepet.expressions"
APP = "桌宠伙伴.app"
HELPER = Path("Contents/Helpers/CodexWhaleExpressions.app/Contents/MacOS/CodexWhaleExpressions")
ENGINES = Path("Contents/Resources/Engines")
NESTED_HELPER = ENGINES / "DeepSeek大肥鱼.app" / HELPER
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
DOMAIN = f"gui/{os.getuid()}"


def run(*args, check=True, env=None):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True, timeout=35, env=env)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"命令失败 {args[0]}")
    return result


def atomic_rename(source, target, flags):
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), flags) != 0:
        reason = ctypes.get_errno()
        raise OSError(reason, os.strerror(reason), str(target))


def atomic_write(path, contents, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".desktop-pet-studio-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(contents)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


@dataclass(frozen=True)
class Agent:
    path: Path
    contents: bytes | None
    mode: int

    @property
    def label(self):
        return self.path.stem

    @classmethod
    def read(cls, path, allowed_arguments):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise RuntimeError(f"登录项路径异常 {path}")
        if not path.exists():
            return cls(path, None, 0o644)
        contents = path.read_bytes()
        values = plistlib.loads(contents)
        if (values.get("Label") != path.stem or values.get("ProgramArguments") not in allowed_arguments
                or values.get("RunAtLoad") is not True or "Program" in values):
            raise RuntimeError(f"登录项与已知配置不符 {path}")
        return cls(path, contents, stat.S_IMODE(path.stat().st_mode))

    def backup(self, directory):
        if self.contents is not None:
            target = directory / self.path.name
            atomic_write(target, self.contents, self.mode)
            if target.read_bytes() != self.contents:
                raise RuntimeError(f"未能验证登录项备份 {target}")

    def restore(self):
        if self.contents is None:
            self.path.unlink(missing_ok=True)
        else:
            atomic_write(self.path, self.contents, self.mode)

    def verify_unchanged(self):
        if self.path.is_symlink():
            raise RuntimeError(f"登录项变成了符号链接 {self.path}")
        if self.contents is None:
            unchanged = not self.path.exists()
        else:
            unchanged = (self.path.is_file() and self.path.read_bytes() == self.contents
                         and stat.S_IMODE(self.path.stat().st_mode) == self.mode)
        if not unchanged:
            raise RuntimeError(f"更新期间登录项发生变化 {self.path}")


def registered(agent):
    info = run("/bin/launchctl", "print", f"{DOMAIN}/{agent.label}", check=False)
    if info.returncode:
        if info.returncode == 113 or "Could not find service" in info.stderr:
            return None
        raise RuntimeError(info.stderr.strip() or f"无法读取登录项状态 {agent.label}")
    path = re.search(r"^\s*path = (.+)$", info.stdout, re.MULTILINE)
    if not path or Path(path[1]) != agent.path:
        raise RuntimeError(f"已注册的登录项来自其他位置 {agent.label}")
    return info.stdout


def unload(agent):
    if registered(agent) is not None:
        run("/bin/launchctl", "bootout", f"{DOMAIN}/{agent.label}")


def load(agent):
    if registered(agent) is None:
        run("/bin/launchctl", "bootstrap", DOMAIN, agent.path)


def lock_held(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError(f"状态锁路径异常 {path}")
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(fd)


def wait_for(check, message, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError(message)


def wait_for_helper(agent, state):
    def ready():
        job = registered(agent)
        if not job or not lock_held(state / "instance.lock"):
            return None
        pid = re.search(r"^\s*pid = (\d+)$", job, re.MULTILINE)
        try:
            report = json.loads((state / "status.json").read_bytes())
        except (FileNotFoundError, ValueError):
            return None
        return int(pid[1]) if pid and report.get("pid") == int(pid[1]) and report.get("running") else None

    return wait_for(ready, "新位置的 Codex 表情助手没有就绪。")


def verify_bundle(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        raise RuntimeError(f"找不到桌宠伙伴应用 {bundle}")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != HUB or info.get("CFBundleExecutable") != "DesktopPetStudio":
        raise RuntimeError(f"应用标识不符 {bundle}")
    binaries = (Path("Contents/MacOS/DesktopPetStudio"), NESTED_HELPER,
                ENGINES / "GPT白龙.app/Contents/MacOS/GPTDragon",
                ENGINES / "DeepSeek大肥鱼.app/Contents/MacOS/DeepSeekWhale")
    for relative in binaries:
        binary = bundle / relative
        if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"应用内的程序不完整 {binary}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", bundle)


@contextmanager
def exclusive_lock(path, busy_message):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise RuntimeError(busy_message) from error
            raise
        yield
    finally:
        os.close(fd)


@contextmanager
def installation_lock(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with exclusive_lock(directory / "install.lock", "桌宠伙伴安装正在进行。"):
        yield


def migrate(source, destination, support, previous, hub_arguments, backup, enable_native=False):
    dragon, helper, hub = previous
    loaded = {agent.label: registered(agent) is not None for agent in previous}
    for agent in previous:
        if loaded[agent.label] and agent.contents is None:
            raise RuntimeError(f"无法备份已注册的登录项 {agent.label}")
    if lock_held(support / "manager.lock"):
        raise RuntimeError("请先退出正在运行的桌宠伙伴，再更新应用。")

    backup.mkdir(parents=True, mode=0o700)
    for agent in previous:
        agent.backup(backup)
    hub_values = {"Label": HUB, "ProgramArguments": hub_arguments,
                  "RunAtLoad": True, "LimitLoadToSessionType": "Aqua"}
    helper_values = plistlib.loads(helper.contents) if helper.contents is not None else None
    if helper_values is None and enable_native:
        helper_values = {"Label": EXPRESSIONS, "RunAtLoad": True, "KeepAlive": {"Crashed": True},
                         "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"}
    if helper_values is not None:
        helper_values["ProgramArguments"] = [str(destination / NESTED_HELPER)]
    state = support.parent / "DeepSeekWhalePet/CodexExpressions"
    stage = Path(tempfile.mkdtemp(dir=destination.parent, prefix=".desktop-pet-studio-install-"))
    staged = stage / APP
    rollback = []
    preserve_stage = False
    helper_pid = None

    def restore_registration(agent):
        load(agent)
        if agent.label == EXPRESSIONS:
            wait_for_helper(agent, state)

    def unload_with_rollback(agent):
        if loaded[agent.label]:
            rollback.append(lambda: restore_registration(agent))
            unload(agent)

    def stop_new_helper():
        unload(helper)
        wait_for(lambda: not lock_held(state / "instance.lock"), "新表情助手仍占用状态锁。")

    try:
        run("/usr/bin/ditto", source, staged)
        verify_bundle(staged)
        unload_with_rollback(helper)
        if helper_values is not None:
            wait_for(lambda: not lock_held(state / "instance.lock"), "旧表情助手仍占用状态锁。")
        unload_with_rollback(dragon)
        unload_with_rollback(hub)
        if destination.exists():
            atomic_rename(staged, destination, RENAME_SWAP)
            rollback.append(lambda: atomic_rename(staged, destination, RENAME_SWAP))
        else:
            atomic_rename(staged, destination, RENAME_EXCL)
            rollback.append(lambda: atomic_rename(destination, staged, RENAME_EXCL))
        verify_bundle(destination)

        if dragon.contents is not None:
            rollback.append(dragon.restore)
            dragon.path.unlink()
        if helper_values is not None:
            rollback.append(helper.restore)
            atomic_write(helper.path, plistlib.dumps(helper_values), helper.mode)
        rollback.append(hub.restore)
        atomic_write(hub.path, plistlib.dumps(hub_values), hub.mode)

        if helper_values is not None:
            rollback.append(stop_new_helper)
            load(helper)
            helper_pid = wait_for_helper(helper, state)
        rollback.append(lambda: unload(hub))
        load(hub)
    except BaseException as error:
        failures = []
        for undo in reversed(rollback):
            try:
                undo()
            except Exception as problem:
                failures.append(str(problem))
        if failures:
            preserve_stage = True
            raise RuntimeError(f"安装失败 {error}\n回滚未完成 {' / '.join(failures)}\n备份 {backup}\n暂存 {stage}") from error
        raise
    finally:
        if not preserve_stage:
            try:
                shutil.rmtree(stage)
            except OSError as error:
                print(f"暂存目录仍保留 {stage}\n{error}")

    return {"installed": str(destination), "loginAgent": str(hub.path),
            "nativeHelperPID": helper_pid, "backups": str(backup)}


def update_bundle(source, destination, support, helper, hub, hub_arguments):
    manager_lock = support / "manager.lock"
    state = support.parent / "DeepSeekWhalePet/CodexExpressions"
    helper_lock = state / "instance.lock"
    registration = registered(helper)
    helper_loaded = registration is not None
    if helper_loaded:
        program = re.search(r"^\s*program = (.+)$", registration, re.MULTILINE)
        if helper.contents is None or not program or Path(program[1]) != destination / NESTED_HELPER:
            raise RuntimeError("已注册的表情助手不属于当前统一应用。")
    elif lock_held(helper_lock):
        raise RuntimeError("表情助手仍在运行，但不属于已迁移的登录项。")

    stage = Path(tempfile.mkdtemp(dir=destination.parent, prefix=".desktop-pet-studio-install-"))
    staged = stage / APP
    manager_stopped = preserve_stage = False
    helper_pid = None
    rollback = []

    def stop_helper():
        unload(helper)
        wait_for(lambda: not lock_held(helper_lock), "表情助手没有释放状态锁。")

    def restart_helper():
        load(helper)
        return wait_for_helper(helper, state)

    try:
        run("/usr/bin/ditto", source, staged)
        verify_bundle(staged)
        if lock_held(manager_lock):
            env = os.environ.copy()
            env.pop("DESKTOP_PET_HUB_DATA_DIR", None)
            response = run(destination / "Contents/MacOS/DesktopPetStudio", "--quit", check=False, env=env)
            if response.returncode and lock_held(manager_lock):
                raise RuntimeError(response.stderr.strip() or "无法正常退出桌宠伙伴。")
            wait_for(lambda: not lock_held(manager_lock), "桌宠伙伴仍在退出，应用没有被替换。", seconds=20)
            manager_stopped = True
        with exclusive_lock(manager_lock, "桌宠伙伴重新打开了，应用没有被替换。"):
            try:
                if helper_loaded:
                    rollback.append(restart_helper)
                    stop_helper()
                for agent in (helper, hub):
                    agent.verify_unchanged()
                atomic_rename(staged, destination, RENAME_SWAP)
                rollback.append(lambda: atomic_rename(staged, destination, RENAME_SWAP))
                verify_bundle(destination)
                if helper_loaded:
                    rollback.append(stop_helper)
                    helper_pid = restart_helper()
                for agent in (helper, hub):
                    agent.verify_unchanged()
            except BaseException as error:
                failures = []
                for undo in reversed(rollback):
                    try:
                        undo()
                    except Exception as problem:
                        failures.append(str(problem))
                if failures:
                    preserve_stage = True
                    raise RuntimeError(f"更新失败 {error}\n回滚未完成 {' / '.join(failures)}\n暂存 {stage}") from error
                raise
    except BaseException as error:
        if manager_stopped and not preserve_stage:
            try:
                run(*hub_arguments)
                wait_for(lambda: lock_held(manager_lock), "旧桌宠伙伴没有重新打开。")
            except Exception as problem:
                raise RuntimeError(f"更新失败 {error}\n旧桌宠伙伴未能重新打开 {problem}") from error
        raise
    finally:
        if not preserve_stage:
            try:
                shutil.rmtree(stage)
            except OSError as error:
                print(f"暂存目录仍保留 {stage}\n{error}")
    return {"updated": str(destination), "managerStopped": manager_stopped,
            "nativeHelperPID": helper_pid, "launchAgentFilesChanged": False}


def install(dry_run, update_only=False, enable_native=False):
    if os.getuid() == 0 or os.getuid() != os.geteuid():
        raise RuntimeError("请以当前桌面用户身份运行安装。")
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    applications = home / "Applications"
    launch_agents = home / "Library/LaunchAgents"
    support = home / "Library/Application Support/DesktopPetStudio"
    source = ROOT / "dist" / APP
    destination = applications / APP
    dragon_app = applications / "GPT龙娘桌面伴侣.app"
    whale_app = applications / "DeepSeek大肥鱼桌宠.app"
    hub_arguments = ["/usr/bin/open", "-g", "-a", str(destination), "--args", "--background"]

    if update_only:
        def update_plan():
            verify_bundle(source)
            verify_bundle(destination)
            helper = Agent.read(launch_agents / f"{EXPRESSIONS}.plist", [[str(destination / NESTED_HELPER)]])
            hub = Agent.read(launch_agents / f"{HUB}.plist", [hub_arguments])
            return helper, hub

        if dry_run:
            helper, hub = update_plan()
            return {"dryRun": True, "updateOnly": True, "signedSource": str(source),
                    "atomicReplace": str(destination), "stopManagerIfRunning": True,
                    "restartExistingHelperIfLoaded": str(helper.path) if helper.contents is not None else None,
                    "preservedLoginAgentFiles": [str(agent.path) for agent in (helper, hub)
                                                 if agent.contents is not None]}

        run("/bin/launchctl", "print", DOMAIN)
        with installation_lock(support):
            helper, hub = update_plan()
            return update_bundle(source, destination, support, helper, hub, hub_arguments)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = support / "Backups" / stamp

    def plan():
        verify_bundle(source)
        if destination.exists() or destination.is_symlink():
            verify_bundle(destination)
        dragon = Agent.read(launch_agents / f"{DRAGON}.plist", [["/usr/bin/open", "-g", str(dragon_app)]])
        helper = Agent.read(launch_agents / f"{EXPRESSIONS}.plist",
                            [[str(whale_app / HELPER)], [str(destination / NESTED_HELPER)]])
        hub = Agent.read(launch_agents / f"{HUB}.plist", [hub_arguments])
        return dragon, helper, hub

    if dry_run:
        dragon, helper, hub = plan()
        return {"dryRun": True, "signedSource": str(source), "atomicInstall": str(destination),
                "backups": str(backup), "backupFiles": [str(agent.path) for agent in (dragon, helper, hub)
                                                          if agent.contents is not None],
                "retireLoginAgent": str(dragon.path) if dragon.contents is not None else None,
                "hubLoginAgent": str(hub.path), "hubArguments": hub_arguments,
                "nativeHelperAgent": str(helper.path) if helper.contents is not None or enable_native else None,
                "nativeHelperProgram": str(destination / NESTED_HELPER) if helper.contents is not None or enable_native else None,
                "stopBeforeUpdatingIfLoaded": [agent.label for agent in (helper, dragon, hub)
                                                if agent.contents is not None],
                "startAfterUpdating": [agent.label for agent in (helper, hub)
                                       if agent is hub or agent.contents is not None or enable_native],
                "waitForNativeHelperLock": str(support.parent / "DeepSeekWhalePet/CodexExpressions/instance.lock"),
                "preservedApplications": [str(dragon_app), str(whale_app)]}

    run("/bin/launchctl", "print", DOMAIN)
    with installation_lock(support):
        previous = plan()
        applications.mkdir(exist_ok=True)
        launch_agents.mkdir(exist_ok=True)
        return migrate(source, destination, support, previous, hub_arguments, backup, enable_native)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="验证签名并列出操作，不修改文件。")
    parser.add_argument("--update-only", action="store_true", help="更新已有统一版应用，保留登录项文件。")
    parser.add_argument("--native-helper", action="store_true", help="同时启用当前用户的 Codex 大肥鱼表情助手。")
    args = parser.parse_args()
    if args.update_only and args.native_helper:
        parser.error("已有统一版请用 --update-only 保留助手设置；首次启用助手使用 --native-helper。")
    try:
        print(json.dumps(install(args.dry_run, args.update_only, args.native_helper), ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
