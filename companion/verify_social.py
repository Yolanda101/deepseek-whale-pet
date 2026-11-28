#!/usr/bin/env python3
"""Exercise coordinated pet interactions in an isolated, muted graphic session."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid


def wait(label, predicate, timeout=22):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.09)
    raise AssertionError(label)


def verify(bundle):
    binary = bundle / "Contents/MacOS/DesktopPetStudio"
    results = {}
    with tempfile.TemporaryDirectory(prefix="desktop-pet-social-qa-") as folder:
        root = Path(folder)
        codex = root / "activity-fixture"
        locks = codex / "thread-writer-locks"
        locks.mkdir(parents=True)
        db = sqlite3.connect(codex / "thread_history_1.sqlite")
        db.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INT, rollout_ordinal INT)")
        db.commit()
        env = {**os.environ, "DESKTOP_PET_HUB_DATA_DIR": str(root), "DESKTOP_PET_HUB_QUIET": "1",
               "DESKTOP_PET_ACTIVITY_TEST_HOME": str(codex), "DESKTOP_PET_SOCIAL_AUTOPLAY_TEST": "1"}
        output = (root / "test.log").open("wb")
        process = subprocess.Popen([str(binary), "--background"], env=env, stdout=output, stderr=output)

        def state():
            try:
                return json.loads((root / "status.json").read_text())
            except (OSError, ValueError):
                return {}

        def command(*args, success=True):
            result = subprocess.run([str(binary), *args], env=env, text=True, capture_output=True, timeout=20)
            assert (result.returncode == 0) == success, result.stdout + result.stderr
            return json.loads(result.stdout)

        def ready():
            pets = state().get("pets", [])
            return len(pets) == 2 and not state().get("interaction") and all(
                p.get("engine", {}).get("interactionReady") for p in pets)

        def engines():
            return [p["engine"] for p in state().get("pets", [])]

        try:
            wait("manager starts", lambda: state().get("running"))
            command("--summon", "dragon")
            command("--summon", "whale")
            wait("both pets ready", ready)
            command("--social", "off")
            for behavior in ("highfive", "nuzzle", "duet", "beckon", "starpass", "chase"):
                wait("ready for " + behavior, ready)
                before = state().get("interactionCompleted", 0)
                response = command("--interact", behavior)
                token = response["interaction"]["id"]
                wait("same interaction acknowledged by both pets", lambda: len(engines()) == 2 and all(
                    (s.get("interaction") or {}).get("id", "").lower() == token.lower() for s in engines()))
                assert len({p["pid"] for p in state()["pets"]}) == 2
                command("--interact", behavior, success=False)
                wait("both complete " + behavior, lambda: state().get("interactionCompleted", 0) == before + 1)
                assert all((s.get("lastInteraction") or {}).get("phase") == "completed" for s in engines())
                assert all((s.get("lastInteraction") or {}).get("behavior") == behavior for s in engines())
                results[behavior] = True
                print("paired", behavior, "passed", flush=True)

            wait("ready for working preemption", ready)
            command("--interact", "starpass")
            thread = str(uuid.uuid4())
            with (locks / (thread + ".lock")).open("wb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                db.execute("INSERT INTO thread_turns VALUES (?, 'inProgress', ?, 0)", (thread, int(time.time())))
                db.commit()
                wait("work cancels coordinated play", lambda: not state().get("interaction") and len(engines()) == 2
                     and all(s.get("working") is True for s in engines()))
                assert all(not s.get("interactionReady") for s in engines())
                command("--interact", "duet", success=False)
                db.execute("DELETE FROM thread_turns WHERE thread_id = ?", (thread,))
                db.commit()
            wait("idle resumes after work", ready)
            results["work_preempts_both"] = True

            command("--interact", "nuzzle")
            command("--cancel-interaction")
            wait("explicit cancel releases both", ready)
            results["explicit_cancel"] = True
            command("--social", "on")
            automatic = wait("idle automatic interaction starts", lambda: state().get("interaction"), timeout=85)
            near = automatic["gap"] <= 110
            assert (automatic["behavior"] in {"highfive", "nuzzle", "duet"}) == near
            wait("idle automatic interaction completes", lambda: not state().get("interaction"), timeout=24)
            results["automatic_play_uses_actual_distance"] = True
            command("--social", "off")
            wait("ready after automatic play", ready)
            command("--interact", "chase")
            dragon = next(p for p in state()["pets"] if p["kind"] == "dragon")
            command("--dismiss", dragon["id"])
            wait("recall cancels peer", lambda: len(engines()) == 1 and not state().get("interaction") and
                 not (engines()[0].get("interaction")))
            results["recall_cancels_peer"] = True
            command("--dismiss-all")
            wait("recall clears instances", lambda: not state().get("pets") and not list((root / "Instances").iterdir()))
            results["recall_removes_process_data"] = True
            command("--quit")
            process.wait(timeout=12)
        finally:
            if process.poll() is None:
                try:
                    command("--quit")
                    process.wait(timeout=12)
                except Exception:
                    process.terminate()
                    process.wait(timeout=8)
            db.close()
            output.close()
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = verify(args.bundle.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False))
