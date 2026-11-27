"""Check or rebuild the Codex appearance from the editable transparent PNG frames.

Requires Pillow with WebP support. The desktop app build uses the packaged atlas.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

from PIL import Image


ROOT = Path(__file__).resolve().parent
FRAMES = ROOT.parent / "assets/figurine/frames"
SHEET = ROOT / "deepseek-q-whale/spritesheet.webp"
LAYOUT = ROOT / "layout.json"
VERIFIED = ROOT / "verified.json"


def compose(layout):
    cell_width, cell_height = layout["cell"]
    scale = layout["transform"]["scale"]
    offset_x, offset_y = layout["transform"]["pixelOffset"]
    atlas = Image.new("RGBA", tuple(layout["canvas"]))

    def place(cell):
        source = FRAMES / cell["source"]
        with Image.open(source) as image:
            if image.mode != "RGBA":
                raise ValueError(f"Transparent RGBA PNG required: {source.name}")
            size = tuple(round(side * scale) for side in image.size)
            resized = image.resize(size, Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (cell_width, cell_height))
        lift = round(cell.get("sourceLiftPx", 0) * scale)
        tile.alpha_composite(resized, (offset_x, offset_y - lift))
        bounds = tile.getchannel("A").point([0] * 8 + [255] * 248).getbbox()
        if not bounds or min(bounds[0], bounds[1], cell_width - bounds[2], cell_height - bounds[3]) < 5:
            raise ValueError(f"Pose is empty or too close to a cell edge: {source.name}")
        atlas.alpha_composite(tile, (cell["column"] * cell_width, cell["row"] * cell_height))
        if "sourceSHA256" in cell:
            cell.update(sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(), visibleBounds=list(bounds))

    for state in layout["states"].values():
        for cell in state["cells"]:
            place(cell)
    neutral = layout["neutral"]
    place({"source": neutral["desktopAndCloud"], "row": neutral["row"], "column": neutral["column"]})
    for cell in layout["gaze"]:
        place(cell)
    # Lossless WebP stores these otherwise invisible RGB pixels as zero.
    atlas.paste((0, 0, 0, 0), mask=atlas.getchannel("A").point([255] + [0] * 255))
    return atlas


def build(write):
    layout = json.loads(LAYOUT.read_bytes())
    before = json.dumps(layout, sort_keys=True)
    atlas = compose(layout)
    if not write:
        with Image.open(SHEET) as current:
            if current.size != atlas.size or current.convert("RGBA").tobytes() != atlas.tobytes():
                raise ValueError("The atlas differs from the source PNG frames.")
        digest = hashlib.sha256(SHEET.read_bytes()).hexdigest()
        if before != json.dumps(layout, sort_keys=True) or digest != json.loads(VERIFIED.read_bytes())["webpSHA256"]:
            raise ValueError("The atlas or its source frame hashes have changed.")
        print(f"Verified {atlas.width} × {atlas.height}, SHA-256 {digest}")
        return
    with tempfile.TemporaryDirectory(dir=ROOT) as temp:
        scratch = Path(temp)
        output = scratch / SHEET.name
        atlas.save(output, lossless=True, quality=100, method=6, exact=True)
        with Image.open(output) as encoded:
            if encoded.convert("RGBA").tobytes() != atlas.tobytes() or output.stat().st_size > 20_000_000:
                raise ValueError("The encoded atlas failed verification.")
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        for file, value in [(LAYOUT, layout), (VERIFIED, {"webpSHA256": digest})]:
            (scratch / file.name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        output.replace(SHEET)
        (scratch / LAYOUT.name).replace(LAYOUT)
        (scratch / VERIFIED.name).replace(VERIFIED)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="replace the atlas and its verification metadata")
    build(parser.parse_args().write)
