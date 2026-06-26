#!/usr/bin/env python3
"""Generate next-candidate voice bakeoff artifacts for PlushPal.

Compares non-Chatterbox candidates against the same toy mid-window references
that sounded best in the focused Chatterbox run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "test-artifacts" / "next-model-bakeoff-2026-06-20"
REFERENCE_ROOT = ROOT / "test-artifacts" / "chatterbox-tuning-2026-06-20" / "references"
SAMPLES = ["Buddy", "Jenna", "Sheru"]
PHRASES = {
    "preview_baby": "Mmm... woof woof... hii tiny friend... we pway now?",
    "slow_baby": "Mmm... hii tiny friend... I am your baby puppy... can we pway... pwease?",
}
REFERENCE_TEXT = {
    "Buddy": "Woof woof, I am Buddy, a tiny baby puppy toy, and I want to play.",
    "Jenna": "Hi hi, I am Jenna, a tiny baby puppy toy, and I want to play.",
    "Sheru": "Woof woof, I am Sheru, a tiny baby puppy toy, and I want to play.",
}


@dataclass(frozen=True)
class Engine:
    name: str
    kind: str
    model: str = ""
    speed: float = 0.92
    voice: str | None = None
    instruct: str | None = None


ENGINES = [
    Engine("qwen3_0_6b_4bit_mid", "mlx", "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"),
    Engine("qwen3_1_7b_8bit_mid", "mlx", "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"),
    Engine(
        "qwen3_customvoice_0_6b_vivian_mid",
        "mlx",
        "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
        0.88,
        "vivian",
        "Speak like a tiny one year old baby puppy plush toy: soft, slow, squeaky, playful, with little pauses and toddler-like pronunciation.",
    ),
    Engine(
        "qwen3_customvoice_0_6b_sohee_mid",
        "mlx",
        "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
        0.88,
        "sohee",
        "Speak like a tiny one year old baby puppy plush toy: soft, slow, squeaky, playful, with little pauses and toddler-like pronunciation.",
    ),
    Engine(
        "qwen3_customvoice_1_7b_vivian_mid",
        "mlx",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        0.88,
        "vivian",
        "Speak like a tiny one year old baby puppy plush toy: soft, slow, squeaky, playful, with little pauses and toddler-like pronunciation.",
    ),
    Engine(
        "qwen3_customvoice_1_7b_sohee_mid",
        "mlx",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        0.88,
        "sohee",
        "Speak like a tiny one year old baby puppy plush toy: soft, slow, squeaky, playful, with little pauses and toddler-like pronunciation.",
    ),
    Engine("luxtts_mid", "luxtts", "YatharthS/LuxTTS"),
    Engine("tada_mid", "mlx", "mlx-community/tada-tts"),
]


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 2_400) -> None:
    subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


def env_for(output_dir: Path) -> dict[str, str]:
    result = os.environ.copy()
    result.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "NUMBA_CACHE_DIR": str(output_dir / "cache" / "numba"),
            "XDG_CACHE_HOME": str(output_dir / "cache"),
        }
    )
    return result


def duration(path: Path) -> float:
    info = sf.info(path)
    return float(info.frames) / float(info.samplerate)


def generate_mlx(engine: Engine, reference: Path, reference_text: str, text: str, output: Path, output_dir: Path) -> None:
    command = [
        str(ROOT / ".venv-mlx-audio/bin/python"),
        str(ROOT / "tools/voice/mlx_audio_tts.py"),
        "--model",
        engine.model,
        "--reference",
        str(reference),
        "--reference-text",
        reference_text,
        "--text",
        text,
        "--output",
        str(output),
        "--speed",
        str(engine.speed),
        "--temperature",
        "0.65",
        "--max-tokens",
        "180",
        "--top-p",
        "0.9",
        "--top-k",
        "30",
    ]
    if engine.voice:
        command.extend(["--voice", engine.voice])
    if engine.instruct:
        command.extend(["--instruct", engine.instruct])
    run(
        command,
        env=env_for(output_dir),
        timeout=3_600,
    )


def generate_luxtts(engine: Engine, reference: Path, text: str, output: Path, output_dir: Path) -> None:
    run(
        [
            str(ROOT / ".venv-luxtts/bin/python"),
            str(ROOT / "tools/voice/luxtts_tts.py"),
            "--model",
            engine.model,
            "--device",
            "mps",
            "--reference",
            str(reference),
            "--text",
            text,
            "--output",
            str(output),
            "--ref-duration",
            "10",
            "--num-steps",
            "4",
            "--speed",
            str(engine.speed),
        ],
        env=env_for(output_dir),
        timeout=2_400,
    )


def write_report(output_dir: Path, results: list[dict[str, object]]) -> None:
    (output_dir / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    lines = [
        "# Next-model baby-puppy voice bakeoff",
        "",
        "Target: performed 1-2-year-old-ish baby puppy toy voice, not a normal child voice.",
        "",
        "All variants use the `mid10` reference slice because Chatterbox mid-window previews sounded better.",
        "",
        "| sample | phrase | engine | status | render seconds | audio duration | file | notes |",
        "|---|---|---:|---|---:|---:|---|---|",
    ]
    for result in results:
        lines.append(
            "| {sample} | {phrase} | {engine} | {status} | {seconds} | {duration} | {file} | {message} |".format(
                sample=result["sample"],
                phrase=result["phrase"],
                engine=result["engine"],
                status="ok" if result["ok"] else "failed",
                seconds=result["seconds"],
                duration=result["duration"] if result["duration"] is not None else "",
                file=result["file"],
                message=str(result["message"]).replace("\n", " ")[:240],
            )
        )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run next-model baby-puppy voice bakeoff")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--samples", nargs="+", default=SAMPLES)
    parser.add_argument("--engines", nargs="+", default=[engine.name for engine in ENGINES])
    parser.add_argument("--keep-going", action="store_true", default=True)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    selected = [engine for engine in ENGINES if engine.name in set(args.engines)]

    results: list[dict[str, object]] = []
    for sample in args.samples:
        reference = REFERENCE_ROOT / sample / "mid10.wav"
        if not reference.is_file():
            raise FileNotFoundError(reference)
        for phrase_key, text in PHRASES.items():
            for engine in selected:
                output = output_dir / sample / phrase_key / f"{engine.name}.wav"
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.monotonic()
                try:
                    print(f"[next-model-bakeoff] {sample} {phrase_key} {engine.name}", flush=True)
                    if engine.kind == "luxtts":
                        generate_luxtts(engine, reference, text, output, output_dir)
                    else:
                        generate_mlx(engine, reference, REFERENCE_TEXT[sample], text, output, output_dir)
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "engine": engine.name,
                            "ok": True,
                            "seconds": round(time.monotonic() - start, 2),
                            "duration": round(duration(output), 2),
                            "file": str(output),
                            "message": "",
                        }
                    )
                except Exception as error:  # noqa: BLE001 - continue by design
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "engine": engine.name,
                            "ok": False,
                            "seconds": round(time.monotonic() - start, 2),
                            "duration": None,
                            "file": "",
                            "message": str(error),
                        }
                    )
                    if not args.keep_going:
                        write_report(output_dir, results)
                        raise
                finally:
                    write_report(output_dir, results)

    print(f"[next-model-bakeoff] report: {output_dir / 'summary.md'}")
    return 0 if all(result["ok"] for result in results) else 2


if __name__ == "__main__":
    raise SystemExit(main())
