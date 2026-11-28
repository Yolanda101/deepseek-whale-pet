#!/usr/bin/env python3
"""Build the GPT White Dragon engine for Desktop Pet Studio."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[1]
SHARED = ROOT / "app" / "shared"
ASSETS = ROOT / "assets" / "dragon"
BUNDLE_IDENTIFIER = "com.local.desktop-pet-studio.dragon-engine"
sys.path.insert(0, str(SOURCE.parent))
from dialogue_assets import install as install_dialogue

SOURCES = (
    SOURCE / "main.swift", SOURCE / "PetStage.swift",
    SOURCE / "GreetingSchedule.swift", SOURCE / "StarPass.swift",
    SOURCE / "WhiteDragonExpressions.swift", SOURCE / "WhiteDragonInteraction.swift",
    SHARED / "ActivityMonitor.swift", SHARED / "NativePetLocator.swift",
    SHARED / "NativePetSize.swift", SHARED / "PetSizeControl.swift",
)
RECORDINGS = {
    "Voice/" + stem + ".wav" for stem in (
        "cheer", "dance", "greeting", "playful", "shy", "sleepy", "star_catch", "star_dance", "task_done",
    )
} | {
    "Care/" + stem + ".wav" for stem in (
        "bailong", "check_in", "good_thing", "hello", "smile", "stretch", "take_it_easy", "water",
    )
} | {
    "Social/" + stem + ".wav" for stem in ("beckon", "chase", "duet", "highfive", "nuzzle", "starpass")
}


def copy_voice_resources(resources):
    approval = json.loads((ASSETS / "Voice/verified.json").read_bytes())
    manifest = json.loads((ASSETS / "Voice/manifest.json").read_bytes())
    hashes = approval["files"]
    lines = manifest["lines"]
    if (approval.get("complete") is not True or approval.get("count") != len(RECORDINGS)
            or set(hashes) != RECORDINGS or {name + ".wav" for name in lines} != RECORDINGS):
        raise ValueError("Expected the approved set of 23 Dragon recordings.")
    captions = "Care/greetings.json"
    caption_hashes = hashes | {captions: approval["careCaptionsSha256"]}
    actual_captions = json.loads((ASSETS / captions).read_bytes())
    expected_captions = {name.removeprefix("Care/"): line for name, line in lines.items() if name.startswith("Care/")}
    if {line["id"]: line["text"] for line in actual_captions} != expected_captions:
        raise ValueError("Dragon care captions differ from the dialogue text in the voice manifest.")
    documents = {"NOTICE.md", "Voice/manifest.json", "Voice/verified.json", "Voice/语音来源.md"}
    for name in sorted(caption_hashes.keys() | documents):
        entry = ASSETS / name
        if not entry.is_file() or entry.is_symlink():
            raise ValueError(f"Missing regular resource file: {entry}")
        content = entry.read_bytes()
        if name in caption_hashes and hashlib.sha256(content).hexdigest() != caption_hashes[name]:
            raise ValueError(f"Dragon voice resource differs from the approved recording or captions: {name}")
        resource = "Voice/" + name if name.startswith("Social/") else name
        target = resources / resource
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def build(output, module_cache):
    output = Path(output).expanduser().absolute()
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"Dragon build output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    module_cache = Path(module_cache).expanduser().resolve()
    with tempfile.TemporaryDirectory(prefix=".dragon-build-", dir=output.parent) as staging:
        bundle = Path(staging) / output.name
        contents = bundle / "Contents"
        resources = contents / "Resources"
        executable = contents / "MacOS" / "GPTDragon"
        executable.parent.mkdir(parents=True)
        copy_voice_resources(resources)
        install_dialogue(resources, "dragon")
        plist = dict(
            CFBundleIdentifier=BUNDLE_IDENTIFIER,
            CFBundleDisplayName="GPT 白龙",
            CFBundleName="GPT 白龙",
            CFBundleExecutable=executable.name,
            CFBundleInfoDictionaryVersion="6.0",
            CFBundlePackageType="APPL",
            CFBundleShortVersionString="1.3",
            CFBundleVersion="4",
            CFBundleDevelopmentRegion="zh_CN",
            LSMinimumSystemVersion="13.0",
            LSUIElement=True,
            NSHighResolutionCapable=True,
            NSPrincipalClass="NSApplication",
        )
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
        subprocess.run([
            "/usr/bin/swiftc", "-O", "-target", "arm64-apple-macos13.0",
            "-module-cache-path", str(module_cache),
            *[str(path.relative_to(ROOT)) for path in SOURCES],
            "-lsqlite3", "-o", str(executable),
        ], cwd=ROOT, check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        bundle.rename(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--module-cache-path", type=Path)
    args = parser.parse_args()
    if args.module_cache_path is None:
        with tempfile.TemporaryDirectory(prefix="dragon-swift-") as cache:
            print(build(args.output, cache))
    else:
        print(build(args.output, args.module_cache_path))
