#!/usr/bin/env python3
"""Focused stability bakeoff for the closest PlushPal voice candidates.

This compares Qwen3-TTS 1.7B Base and LuxTTS with fixed seeds and conservative
sampling/speed settings. The goal is to find repeatable settings that preserve
the baby-puppy toy vibe instead of chasing one lucky preview.
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
DEFAULT_OUTPUT = ROOT / "test-artifacts" / "voice-full-reference-bakeoff-2026-06-20"
REFERENCE_ROOT = ROOT / "test-artifacts" / "chatterbox-tuning-2026-06-20" / "references"
SOURCE_ROOT = ROOT / "test-artifacts" / "chatterbox-tuning-2026-06-20" / "sources"
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
class Variant:
    name: str
    engine: str
    reference_slice: str
    speed: float
    seed: int
    temperature: float = 0.55
    top_p: float = 0.82
    top_k: int = 20
    repetition_penalty: float = 1.08
    ref_duration: float = 10.0
    num_steps: int = 4
    t_shift: float = 0.9


VARIANTS = [
    # Full reference clip variants. These use the entire converted source WAV
    # instead of a 10-second slice, because the toy persona may be encoded across
    # multiple repetitions/pauses in the original recording.
    Variant("qwen17_full_conservative_seed11", "qwen17", "full", 0.90, 11, temperature=0.45, top_p=0.78, top_k=16),
    Variant("qwen17_full_balanced_seed11", "qwen17", "full", 0.88, 11, temperature=0.55, top_p=0.84, top_k=24),
    Variant("qwen17_full_balanced_seed22", "qwen17", "full", 0.88, 22, temperature=0.55, top_p=0.84, top_k=24),
    Variant("luxtts_full_fast_seed11", "luxtts", "full", 0.92, 11, ref_duration=40.0, num_steps=4, t_shift=0.9),
    Variant("luxtts_full_slow_seed11", "luxtts", "full", 0.84, 11, ref_duration=40.0, num_steps=4, t_shift=0.9),
    Variant("luxtts_full_steps8_seed11", "luxtts", "full", 0.88, 11, ref_duration=40.0, num_steps=8, t_shift=0.9),
]


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


def run(command: list[str], *, env: dict[str, str], timeout: int = 3_600) -> None:
    subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


def duration(path: Path) -> float:
    info = sf.info(path)
    return float(info.frames) / float(info.samplerate)


def generate_qwen(variant: Variant, sample: str, reference: Path, text: str, output: Path, output_dir: Path) -> None:
    run(
        [
            str(ROOT / ".venv-mlx-audio/bin/python"),
            str(ROOT / "tools/voice/mlx_audio_tts.py"),
            "--model",
            "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
            "--reference",
            str(reference),
            "--reference-text",
            REFERENCE_TEXT[sample],
            "--text",
            text,
            "--output",
            str(output),
            "--speed",
            str(variant.speed),
            "--temperature",
            str(variant.temperature),
            "--max-tokens",
            "180",
            "--top-p",
            str(variant.top_p),
            "--top-k",
            str(variant.top_k),
            "--repetition-penalty",
            str(variant.repetition_penalty),
            "--seed",
            str(variant.seed),
        ],
        env=env_for(output_dir),
    )


def generate_luxtts(variant: Variant, reference: Path, text: str, output: Path, output_dir: Path) -> None:
    run(
        [
            str(ROOT / ".venv-luxtts/bin/python"),
            str(ROOT / "tools/voice/luxtts_tts.py"),
            "--model",
            "YatharthS/LuxTTS",
            "--device",
            "mps",
            "--reference",
            str(reference),
            "--text",
            text,
            "--output",
            str(output),
            "--ref-duration",
            str(variant.ref_duration),
            "--num-steps",
            str(variant.num_steps),
            "--t-shift",
            str(variant.t_shift),
            "--speed",
            str(variant.speed),
            "--seed",
            str(variant.seed),
        ],
        env=env_for(output_dir),
    )


def write_report(output_dir: Path, results: list[dict[str, object]]) -> None:
    (output_dir / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    lines = [
        "# PlushPal voice stability bakeoff",
        "",
        "Target: consistent 1-2-year-old-ish baby puppy toy voice.",
        "",
        "This run focuses only on the candidates the listener marked closest: LuxTTS and Qwen3-TTS 1.7B Base.",
        "",
        "Each variant uses the full converted source WAV, not a 10-second mid/start/end slice.",
        "",
        "| sample | phrase | variant | status | seconds | duration | file | notes |",
        "|---|---|---:|---|---:|---:|---|---|",
    ]
    for result in results:
        lines.append(
            "| {sample} | {phrase} | {variant} | {status} | {seconds} | {duration} | {file} | {message} |".format(
                sample=result["sample"],
                phrase=result["phrase"],
                variant=result["variant"],
                status="ok" if result["ok"] else "failed",
                seconds=result["seconds"],
                duration=result["duration"] if result["duration"] is not None else "",
                file=result["file"],
                message=str(result["message"]).replace("\n", " ")[:240],
            )
        )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run focused PlushPal voice stability bakeoff")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--samples", nargs="+", default=SAMPLES)
    parser.add_argument("--phrases", nargs="+", default=list(PHRASES))
    parser.add_argument("--variants", nargs="+", default=[variant.name for variant in VARIANTS])
    parser.add_argument("--keep-going", action="store_true", default=True)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    selected = [variant for variant in VARIANTS if variant.name in set(args.variants)]

    results: list[dict[str, object]] = []
    for sample in args.samples:
        for phrase_key in args.phrases:
            text = PHRASES[phrase_key]
            for variant in selected:
                reference = (
                    SOURCE_ROOT / f"{sample}.wav"
                    if variant.reference_slice == "full"
                    else REFERENCE_ROOT / sample / f"{variant.reference_slice}.wav"
                )
                output = output_dir / sample / phrase_key / f"{variant.name}.wav"
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.monotonic()
                try:
                    print(f"[voice-stability] {sample} {phrase_key} {variant.name}", flush=True)
                    if variant.engine == "qwen17":
                        generate_qwen(variant, sample, reference, text, output, output_dir)
                    elif variant.engine == "luxtts":
                        generate_luxtts(variant, reference, text, output, output_dir)
                    else:
                        raise ValueError(f"unknown engine: {variant.engine}")
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "variant": variant.name,
                            "ok": True,
                            "seconds": round(time.monotonic() - start, 2),
                            "duration": round(duration(output), 2),
                            "file": str(output),
                            "message": "",
                        }
                    )
                except Exception as error:  # noqa: BLE001 - keep the matrix running
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "variant": variant.name,
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

    print(f"[voice-stability] report: {output_dir / 'summary.md'}")
    return 0 if all(result["ok"] for result in results) else 2


if __name__ == "__main__":
    raise SystemExit(main())
