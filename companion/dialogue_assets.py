"""Validate the public conversation pack and export per-character resources."""
import hashlib
import json
from pathlib import Path
import shutil
import stat
import wave

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets/dialogue"
BEHAVIORS = {"highfive", "nuzzle", "duet", "beckon", "starpass", "chase"}


def regular(relative):
    path = ASSETS
    for part in Path(relative).parts:
        path /= part
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError(f"Unsupported dialogue entry: {relative}")
    if not path.is_file():
        raise ValueError(f"Missing dialogue file: {relative}")
    return path


def catalog():
    manifest = regular("manifest.json").read_bytes()
    approval = json.loads(regular("verified.json").read_bytes())
    if (approval.get("complete") is not True or approval.get("count") != 36
            or hashlib.sha256(manifest).hexdigest() != approval.get("manifestSHA256")):
        raise ValueError("The public conversation pack has not passed validation.")
    data = json.loads(manifest)
    scripts = data.get("scripts", {})
    names = {f"{behavior}-{speaker}" for behavior in BEHAVIORS for speaker in ("dragon", "whale")}
    if data.get("version") != 1 or set(scripts) != names:
        raise ValueError("Expected twelve three-turn conversations.")
    used = set()
    for name, script in scripts.items():
        speaker = script["initiator"]
        if speaker not in {"dragon", "whale"} or script["behavior"] not in BEHAVIORS or name != script["behavior"] + "-" + speaker:
            raise ValueError(f"Invalid conversation: {name}")
        other = "whale" if speaker == "dragon" else "dragon"
        turns = script["turns"]
        if len(turns) != 3 or [t["speaker"] for t in turns] != [speaker, other, speaker]:
            raise ValueError(f"Invalid speaker order: {name}")
        for index, turn in enumerate(turns):
            filename = f"{name}-{index}.wav"
            if turn["index"] != index or turn["file"] != filename or not turn["text"].strip():
                raise ValueError(f"Invalid conversation turn: {name}")
            relative = turn["speaker"] + "/" + filename
            file = regular(relative)
            if relative in used or hashlib.sha256(file.read_bytes()).hexdigest() != approval["files"].get(relative):
                raise ValueError(f"Conversation recording differs from approval: {relative}")
            used.add(relative)
            with wave.open(str(file)) as audio:
                if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (24000, 1, 2):
                    raise ValueError(f"Invalid conversation PCM: {relative}")
                duration = audio.getnframes() / audio.getframerate()
            if not 0.2 <= duration <= 6 or abs(duration - turn["duration"]) > 0.001:
                raise ValueError(f"Conversation duration differs: {relative}")
    if used != set(approval["files"]):
        raise ValueError("Unexpected or missing conversation recordings.")
    return data


def install(resources, speaker=None):
    if speaker not in {None, "dragon", "whale"}:
        raise ValueError("Unknown conversation speaker.")
    data = catalog()
    destination = Path(resources) / "Dialogue"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("manifest.json", "verified.json", "语音来源.md"):
        shutil.copyfile(regular(name), destination / name)
    if speaker:
        for script in data["scripts"].values():
            for turn in script["turns"]:
                if turn["speaker"] == speaker:
                    shutil.copyfile(regular(speaker + "/" + turn["file"]), destination / turn["file"])
