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
DEFAULT_SEED = 738
TAKE_SEEDS = {"feeding": 451, "crying": 192, "remorse": 193, "angry": 451}
TRIM_LEAD_MS = {
    "dance": 280,
    "dizzy": 350,
    "hungry": 400,
    "outing": 270,
    "playful": 400,
    "remorse": 230,
    "rice": 310,
    "tailwag": 360,
    "task_done": 320,
}


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


def write_take(path, waveform, rate):
    wave = np.asarray(waveform, dtype=np.float32).squeeze()
    if wave.ndim != 1 or len(wave) < rate / 3 or not np.isfinite(wave).all():
        raise ValueError(f"Invalid generated waveform for {path.name}")
    block = max(1, rate // 100)
    pad = (-len(wave)) % block
    energy = (np.pad(wave, (0, pad)).reshape(-1, block) ** 2).mean(axis=1)
    active = np.flatnonzero(energy > 10 ** (-49 / 10))
    if not len(active):
        raise ValueError(f"No speech found for {path.name}")
    start = max(0, (active[0] - 7) * block)
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
        "durationSeconds": round(len(pcm) / rate, 3),
        "durationMs": round(len(pcm) * 1000 / rate),
        "sampleRateHz": rate,
        "lufs": float(measured["input_i"]),
        "truePeakDb": float(measured["input_tp"]),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def render_result(output, results):
    import mlx.core as mx

    clips = list(results)
    if len(clips) != 1:
        raise RuntimeError(
            f"Expected one complete utterance, got {len(clips)} segments"
        )
    audio = clips[0].audio
    mx.eval(audio)
    return write_take(output, audio, int(clips[0].sample_rate))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "model", type=Path, help="Local Qwen3-TTS 1.7B Base MLX BF16 directory"
    )
    parser.add_argument("--output", type=Path, default=VOICE)
    parser.add_argument("--only", nargs="+")
    args = parser.parse_args()
    text = json.loads((VOICE / "manifest.json").read_text())["lines"]
    names = args.only or list(text)
    if set(names) - set(text):
        parser.error("Unknown line ID")
    options = json.loads((PRODUCTION / "reference.json").read_text())
    reference = PRODUCTION / "reference.wav"
    check_file(reference, options["referenceSha256"])
    model = None
    if any(name != "greeting" for name in names):
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        check_file(args.model / "model.safetensors", BASE_WEIGHTS)
        check_file(args.model / "speech_tokenizer/model.safetensors", CODEC_WEIGHTS)
        model = load_model(str(args.model))
    args.output.mkdir(parents=True, exist_ok=True)
    log = args.output / "production" / "recordings.json"
    log.parent.mkdir(exist_ok=True)
    records = json.loads(log.read_text()) if log.is_file() else {}
    for name in names:
        caption = text[name][0]["text"]
        dest = args.output / text[name][0]["file"]
        if name == "greeting":
            source = PRODUCTION / "greeting-original.wav"
            check_file(source, options["greetingSha256"])
            rate, samples = wavfile.read(source)
            start = round(options["greetingTrimStartSeconds"] * rate)
            recorded = write_take(
                dest, samples[start:].astype(np.float32) / 32768, rate
            )
            recorded.update(
                source="Qwen official Space, Qwen3-TTS-12Hz-1.7B-Base",
                sourceSHA256=options["greetingSha256"],
                sourceTrimStartSeconds=options["greetingTrimStartSeconds"],
            )
        else:
            seed = TAKE_SEEDS.get(name, DEFAULT_SEED)
            mx.random.seed(seed)
            results = model.generate(
                text=caption,
                ref_audio=str(reference),
                ref_text=options["referenceText"],
                lang_code="Chinese",
                temperature=0.82,
                top_p=0.96,
                max_tokens=170,
            )
            recorded = render_result(dest, results)
            recorded["seed"] = seed
            if name in TRIM_LEAD_MS:
                rate, samples = wavfile.read(dest)
                offset = round(TRIM_LEAD_MS[name] * rate / 1000)
                recorded.update(
                    write_take(dest, samples[offset:].astype(np.float32) / 32768, rate)
                )
                recorded["trimLeadMs"] = TRIM_LEAD_MS[name]
        records[name] = {**recorded, "text": caption}
        staged = log.with_suffix(".tmp")
        staged.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
        staged.replace(log)
        print(f"{name} {recorded['durationMs']} ms", flush=True)


if __name__ == "__main__":
    main()
