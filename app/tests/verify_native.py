#!/usr/bin/env python3
"""Run the native expression panel in transparent, click-through test windows."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def verify(bundle, output):
    directory = Path(__file__).resolve().parent
    app = directory.parent
    shared = app / "shared"
    with tempfile.TemporaryDirectory(prefix="native-whale-fixture-") as temp:
        binary = Path(temp) / "verify-native"
        sources = [directory / "NativeExpressions.swift"]
        sources.extend(app / file for file in ("Animation.swift", "WhaleSpeech.swift", "ExpressionPanel.swift", "NativeWhaleInteraction.swift",
                                               "NativeWhaleTarget.swift"))
        sources.extend(shared / file for file in ("ActivityMonitor.swift", "NativePetSize.swift", "NativePetLocator.swift"))
        subprocess.run(["/usr/bin/swiftc", "-O", "-parse-as-library", "-module-cache-path",
                        str(Path(tempfile.gettempdir()) / "deepseek-whale-swift-cache"), *sources,
                        "-lsqlite3", "-o", binary], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([binary, bundle.resolve() / "Contents/Resources", output.resolve()], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="离屏验证原生鲸的完整表情点播，不操作系统鼠标")
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    verify(args.bundle, args.output)
