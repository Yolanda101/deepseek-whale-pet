#!/usr/bin/env python3
"""Verify both characters' real audio replies and cancellation in isolated data."""
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


def wait(label, predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.07)
    raise AssertionError(label)


def verify(bundle):
    binary = bundle / "Contents/MacOS/DesktopPetStudio"
    catalog = json.loads((bundle / "Contents/Resources/Dialogue/manifest.json").read_text())["scripts"]
    results = {"scripts": {}, "real_players_at_zero_volume": True}
    with tempfile.TemporaryDirectory(prefix="desktop-pet-dialogue-qa-") as folder:
        root = Path(folder)
        fixture = root / "activity"
        locks = fixture / "thread-writer-locks"
        locks.mkdir(parents=True)
        db = sqlite3.connect(fixture / "thread_history_1.sqlite")
        db.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INT, rollout_ordinal INT)")
        db.commit()
        env = {**os.environ, "DESKTOP_PET_HUB_DATA_DIR": str(root), "DESKTOP_PET_HUB_QUIET": "1",
               "DESKTOP_PET_ACTIVITY_TEST_HOME": str(fixture), "DESKTOP_PET_AUDIO_TEST_SILENT": "1"}
        log = (root / "output.log").open("wb")
        process = subprocess.Popen([str(binary), "--background"], env=env, stdout=log, stderr=log)

        def snapshot():
            try:
                return json.loads((root / "status.json").read_text())
            except (ValueError, OSError):
                return {}

        def command(*args):
            run = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=20)
            assert run.returncode == 0, run.stderr + run.stdout
            return json.loads(run.stdout)

        def pets():
            return snapshot().get("pets", [])

        def engines():
            return [pet.get("engine", {}) for pet in pets()]

        def ready():
            return len(engines()) == 2 and not snapshot().get("interaction") and all(
                engine.get("interactionReady") for engine in engines())

        def matching_dialogues(token):
            return [record for engine in engines()
                    if isinstance(record := engine.get("lastDialogue"), dict)
                    and record.get("id", "").lower() == token.lower()]

        def playing():
            return any(isinstance(d := engine.get("dialogue"), dict) and d.get("speaking") for engine in engines())

        try:
            wait("manager starts", lambda: snapshot().get("running"))
            command("--social", "off")
            command("--summon", "dragon")
            command("--summon", "whale")
            wait("both pets ready", ready)
            assert all(engine.get("muted") is False for engine in engines())
            for name, script in catalog.items():
                wait("ready for " + name, ready)
                before = snapshot().get("interactionCompleted", 0)
                plan = command("--interact", script["behavior"], script["initiator"])["interaction"]
                assert plan["dialogueScript"] == name
                wait("conversation completes " + name,
                     lambda: snapshot().get("interactionCompleted", 0) == before + 1, timeout=32)
                records = matching_dialogues(plan["id"])
                assert len(records) == 2 and all(r.get("phase") == "completed" for r in records), records
                actual = sorted([turn for record in records for turn in record["turns"]], key=lambda turn: turn["index"])
                assert [turn["index"] for turn in actual] == [0, 1, 2]
                for observed, expected in zip(actual, script["turns"]):
                    assert observed["speaker"] == expected["speaker"]
                    assert observed["text"] == expected["text"] and observed["file"] == expected["file"]
                    assert observed["outcome"] == "completed", observed
                    elapsed = observed["completedAt"] - observed["startedAt"]
                    assert expected["duration"] - .035 <= elapsed <= expected["duration"] + .3, (observed, expected)
                gaps = [actual[i + 1]["startedAt"] - actual[i]["completedAt"] for i in (0, 1)]
                assert min(gaps) >= .06, gaps
                assert actual[-1]["completedAt"] <= plan["startAt"] + plan["duration"] + .1
                results["scripts"][name] = {"turns": 3, "both_voices": True, "no_overlap": True,
                                               "minimum_gap_seconds": round(min(gaps), 3)}
                print("dialogue", name, "passed", flush=True)

            wait("ready for interruption", ready)
            plan = command("--interact", "starpass", "dragon")["interaction"]
            wait("dialogue actually playing", playing)
            thread = str(uuid.uuid4())
            with (locks / (thread + ".lock")).open("wb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                db.execute("INSERT INTO thread_turns VALUES (?, 'inProgress', ?, 0)", (thread, int(time.time())))
                db.commit()
                wait("work cancels both voices", lambda: len(engines()) == 2 and not snapshot().get("interaction")
                     and all(e.get("working") is True and not (e.get("dialogue") or {}).get("speaking") for e in engines()))
                records = matching_dialogues(plan["id"])
                assert len(records) == 2 and all(r["phase"] == "cancelled" for r in records)
                frozen = json.dumps(records, sort_keys=True)
                deadline = plan["startAt"] + plan["duration"] + .4
                wait("old sequence time has passed", lambda: time.monotonic() >= deadline, timeout=26)
                assert json.dumps(matching_dialogues(plan["id"]), sort_keys=True) == frozen
                db.execute("DELETE FROM thread_turns WHERE thread_id=?", (thread,))
                db.commit()
            results["work_cancels_both_and_no_late_reply"] = True
            wait("ready after work", ready)
            plan = command("--interact", "nuzzle", "whale")["interaction"]
            wait("second conversation playing", playing)
            dragon = next(p for p in pets() if p["kind"] == "dragon")
            worker_env = {**env, "DESKTOP_PET_MANAGED": "1", "DESKTOP_PET_INSTANCE_ID": dragon["id"],
                          "DESKTOP_PET_INSTANCE_DIR": str(root / "Instances" / dragon["id"])}
            worker = bundle / "Contents/Resources/Engines/GPT白龙.app/Contents/MacOS/GPTDragon"
            run = subprocess.run([str(worker), "--action", "greeting"], env=worker_env, capture_output=True, timeout=10)
            assert run.returncode == 0
            wait("expression cancels paired dialogue", lambda: not snapshot().get("interaction") and
                 len(matching_dialogues(plan["id"])) == 2 and
                 all(record["phase"] == "cancelled" for record in matching_dialogues(plan["id"])))
            results["manual_expression_cancels_both"] = True
            command("--dismiss-all")
            wait("no retired data", lambda: not pets() and not list((root / "Instances").iterdir()))
            command("--quit")
            process.wait(timeout=12)
            results["recall_cleans_data"] = True
        except BaseException:
            log.flush()
            failure = {"snapshot": snapshot(), "log": (root / "output.log").read_text(errors="replace")[-4000:]}
            report = Path(__file__).parent / "qa/dialogue-failure.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps(failure, ensure_ascii=False, indent=2) + "\n")
            raise
        finally:
            if process.poll() is None:
                try:
                    command("--quit")
                    process.wait(timeout=12)
                except Exception:
                    process.terminate()
                    process.wait(timeout=8)
            db.close()
            log.close()
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
