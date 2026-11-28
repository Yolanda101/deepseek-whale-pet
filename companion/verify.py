#!/usr/bin/env python3
"""Verify one pet per kind, retired data cleanup, sizing and lifecycle."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid


def wait(description, predicate, timeout=16):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.07)
    raise AssertionError(description)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def verify(bundle):
    binary = bundle / "Contents/MacOS/DesktopPetStudio"
    with tempfile.TemporaryDirectory(prefix="desktop-pet-studio-qa-") as folder:
        root = Path(folder)
        env = {**os.environ, "DESKTOP_PET_HUB_DATA_DIR": str(root), "DESKTOP_PET_HUB_QUIET": "1"}
        artwork = env.pop("DESKTOP_PET_DRAGON_ARTWORK_DIR", None)
        if artwork:
            imported = subprocess.run([str(binary), "--import-dragon", artwork], env=env,
                                      capture_output=True, text=True, timeout=20)
            assert imported.returncode == 0, imported.stderr
            assert json.loads(imported.stdout) == {"imported": True, "frames": 51}
            files = sorted((root / "DragonArtwork").rglob("*.png"))
            assert len(files) == 51
            before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            invalid = subprocess.run([str(binary), "--import-dragon", str(root / "missing")], env=env,
                                     capture_output=True, text=True, timeout=10)
            assert invalid.returncode != 0
            assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            repeated = subprocess.run([str(binary), "--import-dragon", artwork], env=env,
                                      capture_output=True, text=True, timeout=20)
            assert repeated.returncode == 0, repeated.stderr
            assert len(list((root / "DragonArtwork").rglob("*.png"))) == 51
        log = (root / "manager.log").open("wb")
        manager = None
        owned = set()

        def snapshot():
            try:
                return json.loads((root / "status.json").read_text())
            except (OSError, ValueError):
                return {}

        def request(*args, ok=True):
            result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=18)
            assert (result.returncode == 0) == ok, result.stderr + result.stdout
            return json.loads(result.stdout)

        def start():
            nonlocal manager
            manager = subprocess.Popen([str(binary), "--background"], env=env, stdout=log, stderr=log)
            wait("manager ready", lambda: snapshot().get("pid") == manager.pid and snapshot().get("running"))

        def settled(count):
            def ready():
                state = snapshot()
                pets = state.get("pets", [])
                if (state.get("restoring") or len(pets) != count or
                        any(not p.get("running") or not p.get("engine", {}).get("instanceID") for p in pets)):
                    return None
                owned.update(p["pid"] for p in pets)
                return state
            return wait(f"{count} workers ready", ready)

        def pet(kind):
            return next((p for p in snapshot().get("pets", []) if p["kind"] == kind), None)

        def resize(kind, width):
            request("--size", kind, str(width))
            mode = "follow-codex" if width == "follow" else "independent"
            return wait("size applied", lambda: (
                (p := pet(kind)) and p["engine"].get("sizeSetting") == mode and
                (width == "follow" or p["engine"].get("petWidth") == width) and p))

        def instance(id):
            return root / "Instances" / id

        try:
            start()
            clients = [subprocess.Popen([str(binary), "--summon", "dragon"], env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                       for _ in range(2)]
            for client in clients:
                out, err = client.communicate(timeout=20)
                assert client.returncode == 0 and json.loads(out)["lastCommand"]["ok"], err + out
            first = settled(1)["pets"][0]
            request("--summon", "dragon")
            assert settled(1)["pets"][0]["pid"] == first["pid"]
            request("--summon", "whale")
            two = settled(2)
            assert {p["kind"] for p in two["pets"]} == {"dragon", "whale"}
            assert len({p["pid"] for p in two["pets"]}) == 2
            assert len({p["engine"]["windowNumber"] for p in two["pets"]}) == 2
            assert all(p["engine"]["muted"] and not p["engine"]["menuBarIcon"] for p in two["pets"])
            assert all(not any(c.isdigit() for c in p["title"]) for p in two["pets"])
            request("--summon", "whale", "--count", "2", ok=False)
            assert len(settled(2)["pets"]) == 2
            resize("dragon", 80)
            resize("whale", 224)
            assert pet("dragon")["engine"]["petWidth"] == 80
            for invalid in ("79", "225", "123.5", "invalid"):
                request("--size", "dragon", invalid, ok=False)
            resize("dragon", "follow")
            resized_whale = resize("whale", 181)

            old_dragon = pet("dragon")
            request("--dismiss", old_dragon["id"])
            settled(1)
            wait("retired process stopped", lambda: not alive(old_dragon["pid"]))
            wait("retired data removed", lambda: not instance(old_dragon["id"]).exists())
            assert pet("whale")["pid"] == resized_whale["pid"]

            for width in (100, 160, 200):
                request("--summon", "dragon")
                request("--size", "dragon", str(width))
                settled(2)
                current = wait("startup resize retained", lambda: (
                    (p := pet("dragon")) and p["engine"].get("petWidth") == width and p))
                request("--dismiss", current["id"])
                settled(1)
                wait("cycle data removed", lambda: not instance(current["id"]).exists())
                assert len(list((root / "Instances").iterdir())) == 1

            request("--summon", "dragon")
            pair = settled(2)
            wait("per-kind size saved", lambda: pet("dragon")["engine"].get("petWidth") == 200)
            preferences = json.loads((root / "preferences.json").read_text())
            assert "nextNumber" not in preferences and all("number" not in p for p in preferences["pets"])
            ids = {p["id"] for p in pair["pets"]}
            pids = {p["pid"] for p in pair["pets"]}
            request("--quit")
            manager.wait(timeout=12)
            wait("normal quit collects workers", lambda: not any(alive(pid) for pid in pids))
            start()
            recovered = settled(2)
            assert {p["id"] for p in recovered["pets"]} == ids
            recovered_pids = {p["pid"] for p in recovered["pets"]}
            manager.kill()
            manager.wait(timeout=5)
            start()
            after_crash = settled(2)
            assert not {p["pid"] for p in after_crash["pets"]} & recovered_pids
            wait("old workers exited", lambda: not any(alive(pid) for pid in recovered_pids))
            request("--dismiss-all")
            settled(0)
            wait("all instance data removed", lambda: not list((root / "Instances").iterdir()))
            request("--quit")
            manager.wait(timeout=10)
            start()
            settled(0)
            request("--quit")
            manager.wait(timeout=10)
            wait("all QA workers exited", lambda: not any(alive(pid) for pid in owned))
            return {
                "maximum_one_each": True, "both_kinds_together": True,
                "concurrent_duplicates_idempotent": True, "no_accumulating_numbers": True,
                "retired_process_and_data_removed": True, "repeated_recall_cycles": 3,
                "sizes_80_224_and_follow": True, "independent_sizes": True,
                "size_while_starting": True, "size_preserved_after_recall": True,
                "invalid_sizes_rejected": True, "no_menu_bar_icons": True,
                "normal_quit_restore": True, "forced_quit_immediate_reopen": True,
                "dismiss_all_no_instance_data": True, "no_orphan_workers": True,
                "muted_isolated_test": True, "imported_artwork_and_invalid_import_guard": bool(artwork)}
        except BaseException:
            out = Path(__file__).resolve().parent / "qa/last-failure.json"
            out.parent.mkdir(parents=True, exist_ok=True)
            log.flush()
            out.write_text(json.dumps({"snapshot": snapshot(),
                                       "log": (root / "manager.log").read_text(errors="replace")[-5000:],
                                       "live_pids": [pid for pid in owned if alive(pid)]},
                                      ensure_ascii=False, indent=2) + "\n")
            raise
        finally:
            if manager is not None and manager.poll() is None:
                manager.terminate()
                try:
                    manager.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    manager.kill()
                    manager.wait()
            for pid in owned:
                if alive(pid):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            log.close()


def verify_data_guards(bundle):
    binary = bundle / "Contents/MacOS/DesktopPetStudio"
    for case in ("unreadable_preferences", "uuid_regular_file", "linked_container", "dialogue_permit_directory"):
        with tempfile.TemporaryDirectory(prefix="desktop-pet-studio-data-guard-") as folder:
            root = Path(folder)
            valid = b'{"restoreOnLaunch":false,"pets":[],"widths":{}}'
            prefs = b'{"incomplete":' if case == "unreadable_preferences" else valid
            (root / "preferences.json").write_bytes(prefs)
            id = str(uuid.uuid4()).upper()
            if case == "linked_container":
                outside = root / "preserved"
                outside.mkdir()
                (root / "Instances").symlink_to(outside, target_is_directory=True)
            elif case == "dialogue_permit_directory":
                outside = root / "dialogue-session.json"
                outside.mkdir()
            else:
                outside = root / "Instances"
                outside.mkdir()
            if case == "uuid_regular_file":
                sentinel = outside / id
            else:
                (outside / id).mkdir()
                sentinel = outside / id / "keep.txt"
            sentinel.write_text("must remain")
            env = {**os.environ, "DESKTOP_PET_HUB_DATA_DIR": str(root), "DESKTOP_PET_HUB_QUIET": "1"}
            process = subprocess.Popen([str(binary), "--background"], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                wait("guard manager ready", lambda: (root / "status.json").is_file())
                time.sleep(0.75)
                assert sentinel.read_text() == "must remain", case
                if case == "unreadable_preferences":
                    assert (root / "preferences.json").read_bytes() == prefs
                result = subprocess.run([str(binary), "--quit"], env=env, capture_output=True, timeout=10)
                assert result.returncode == 0
                process.wait(timeout=10)
                assert sentinel.read_text() == "must remain", case
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = verify(args.bundle.resolve())
    result["invalid_preferences_and_directory_guards"] = verify_data_guards(args.bundle.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False))
