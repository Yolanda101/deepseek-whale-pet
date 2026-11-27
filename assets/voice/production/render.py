"""Render complete Mandarin desktop-pet lines from the bundled synthetic reference."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from scipy.io import wavfile

PRODUCTION = Path(__file__).resolve().parent
VOICE = PRODUCTION.parent
BASE_WEIGHTS = "81fb76175ff74e69be25fef2cc3e54f016df3034f1514c8e1c89da06a3510cff"
CODEC_WEIGHTS = "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_file(path, expected):
    if digest(path) != expected:
        raise ValueError(f"Incorrect content for {path.name}")


def measure(path):
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-af",
            "loudnorm=I=-19:TP=-2:LRA=9:print_format=json",
            "-f",
            "null",
            "-",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(
        result.stderr[result.stderr.rfind("{") : result.stderr.rfind("}") + 1]
    )


def write_take(path, waveform, rate, trim_start_ms=0):
    wave = np.asarray(waveform, dtype=np.float32).squeeze()
    if wave.ndim != 1 or len(wave) < rate / 3 or not np.isfinite(wave).all():
        raise ValueError(f"Invalid generated waveform for {path.name}")
    block = max(1, rate // 100)
    pad = (-len(wave)) % block
    energy = (np.pad(wave, (0, pad)).reshape(-1, block) ** 2).mean(axis=1)
    active = np.flatnonzero(energy > 10 ** (-49 / 10))
    if not len(active):
        raise ValueError(f"No speech found for {path.name}")
    start = max(round(trim_start_ms * rate / 1000), (active[0] - 7) * block, 0)
    stop = min(len(wave), (active[-1] + 12) * block)
    wave = wave[start:stop].copy()
    with tempfile.TemporaryDirectory() as tmp:
        original = Path(tmp) / "raw.wav"
        wavfile.write(original, rate, wave)
        levels = measure(original)
    gain = min(-19 - float(levels["input_i"]), -2 - float(levels["input_tp"]))
    wave *= 10 ** (gain / 20)
    path.parent.mkdir(exist_ok=True, parents=True)
    pcm = np.rint(np.clip(wave, -1, 1) * 32767).astype(np.int16)
    wavfile.write(path, rate, pcm)
    measured = measure(path)
    return {
        "file": path.name,
        "rawStartMs": round(1000 * start / rate),
        "rawEndMs": round(1000 * stop / rate),
        "durationSeconds": round(len(pcm) / rate, 3),
        "durationMs": round(len(pcm) * 1000 / rate),
        "sampleRateHz": rate,
        "lufs": float(measured["input_i"]),
        "truePeakDb": float(measured["input_tp"]),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def render_result(output, results, trim_start_ms=0, raw_output=None):
    import mlx.core as mx

    clips = list(results)
    if len(clips) != 1:
        raise RuntimeError(
            f"Expected one complete utterance, got {len(clips)} segments"
        )
    audio = clips[0].audio
    mx.eval(audio)
    rate = int(clips[0].sample_rate)
    if raw_output:
        raw_output.mkdir(exist_ok=True, parents=True)
        wavfile.write(
            raw_output / output.name,
            rate,
            np.asarray(audio, dtype=np.float32).squeeze(),
        )
    return write_take(output, audio, rate, trim_start_ms)


def main():
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "model", type=Path, help="Local Qwen3-TTS 1.7B Base MLX BF16 directory"
    )
    parser.add_argument("--output", type=Path, default=VOICE)
    parser.add_argument("--only", nargs="+")
    parser.add_argument(
        "--seed", type=int, help="Override the chosen take for an audition"
    )
    parser.add_argument(
        "--raw", type=Path, help="Optional directory for unedited float waveforms"
    )
    args = parser.parse_args()
    lines = json.loads((VOICE / "manifest.json").read_text())["lines"]
    names = args.only or list(lines)
    if set(names) - set(lines):
        parser.error("Unknown line ID")
    options = json.loads((PRODUCTION / "reference.json").read_text())
    reference = PRODUCTION / "reference.wav"
    check_file(reference, options["referenceSha256"])
    check_file(args.model / "model.safetensors", BASE_WEIGHTS)
    check_file(args.model / "speech_tokenizer/model.safetensors", CODEC_WEIGHTS)
    recipe = json.loads((PRODUCTION / "takes.json").read_text())
    model = load_model(str(args.model))
    log = args.output / "production" / "recordings.json"
    log.parent.mkdir(parents=True, exist_ok=True)
    records = json.loads(log.read_text()) if log.is_file() else {}
    for name in names:
        take = recipe["takes"].get(name, {})
        seed = (
            args.seed
            if args.seed is not None
            else take.get("seed", recipe["defaultSeed"])
        )
        trim = take.get("trimStartMs", 0) if args.seed is None else 0
        line = lines[name][0]
        mx.random.seed(seed)
        results = model.generate(
            text=line["text"],
            ref_audio=str(reference),
            ref_text=options["referenceText"],
            lang_code="Chinese",
            temperature=0.82,
            top_p=0.96,
            max_tokens=170,
        )
        recorded = render_result(args.output / line["file"], results, trim, args.raw)
        records[name] = {
            **recorded,
            "seed": seed,
            "text": line["text"],
            "referenceSha256": options["referenceSha256"],
        }
        staged = log.with_suffix(".tmp")
        staged.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
        staged.replace(log)
        print(name, recorded["durationMs"], "ms", flush=True)


if __name__ == "__main__":
    main()
