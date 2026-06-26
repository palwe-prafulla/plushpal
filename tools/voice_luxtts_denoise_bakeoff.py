#!/usr/bin/env python3
"""Run LuxTTS steps8 against original and denoised full references."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path

import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "test-artifacts" / "voice-denoise-bakeoff-2026-06-20"
SOURCE_ROOT = ROOT / "test-artifacts" / "chatterbox-tuning-2026-06-20" / "sources"
SAMPLES = ["Buddy", "Jenna", "Sheru"]
PHRASES = {
    "preview_baby": "Mmm... woof woof... hii tiny friend... we pway now?",
    "slow_baby": "Mmm... hii tiny friend... I am your baby puppy... can we pway... pwease?",
}
REFERENCE_VARIANTS = ["original", "mild", "medium", "strong"]


def env_for(output_dir: Path) -> dict[str, str]:
    result = os.environ.copy()
    result.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "XDG_CACHE_HOME": str(output_dir / "cache"),
        }
    )
    return result


def reference_path(output_dir: Path, sample: str, variant: str) -> Path:
    if variant == "original":
        return SOURCE_ROOT / f"{sample}.wav"
    return output_dir / "references" / variant / f"{sample}.wav"


def duration(path: Path) -> float:
    info = sf.info(path)
    return float(info.frames) / float(info.samplerate)


def run(command: list[str], *, env: dict[str, str], timeout: int = 2_400) -> None:
    subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


def write_report(output_dir: Path, results: list[dict[str, object]]) -> None:
    (output_dir / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    lines = [
        "# LuxTTS denoised-reference bakeoff",
        "",
        "Target: keep the close `luxtts_full_steps8_seed11` match while reducing car/background noise transfer.",
        "",
        "All generated previews use full-length references and LuxTTS settings: `num_steps=8`, `speed=0.88`, `t_shift=0.9`, `seed=11`.",
        "",
        "| sample | phrase | reference | status | seconds | duration | file | notes |",
        "|---|---|---:|---|---:|---:|---|---|",
    ]
    for result in results:
        lines.append(
            "| {sample} | {phrase} | {reference} | {status} | {seconds} | {duration} | {file} | {message} |".format(
                sample=result["sample"],
                phrase=result["phrase"],
                reference=result["reference"],
                status="ok" if result["ok"] else "failed",
                seconds=result["seconds"],
                duration=result["duration"] if result["duration"] is not None else "",
                file=result["file"],
                message=str(result["message"]).replace("\n", " ")[:240],
            )
        )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run LuxTTS denoise bakeoff")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--samples", nargs="+", default=SAMPLES)
    parser.add_argument("--phrases", nargs="+", default=list(PHRASES))
    parser.add_argument("--references", nargs="+", default=REFERENCE_VARIANTS)
    parser.add_argument("--keep-going", action="store_true", default=True)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, object]] = []

    for sample in args.samples:
        for phrase_key in args.phrases:
            for reference_variant in args.references:
                reference = reference_path(output_dir, sample, reference_variant)
                output = output_dir / sample / phrase_key / f"luxtts_full_steps8_seed11_{reference_variant}.wav"
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.monotonic()
                try:
                    print(f"[luxtts-denoise] {sample} {phrase_key} {reference_variant}", flush=True)
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
                            PHRASES[phrase_key],
                            "--output",
                            str(output),
                            "--ref-duration",
                            "40",
                            "--num-steps",
                            "8",
                            "--t-shift",
                            "0.9",
                            "--speed",
                            "0.88",
                            "--seed",
                            "11",
                        ],
                        env=env_for(output_dir),
                    )
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "reference": reference_variant,
                            "ok": True,
                            "seconds": round(time.monotonic() - start, 2),
                            "duration": round(duration(output), 2),
                            "file": str(output),
                            "message": "",
                        }
                    )
                except Exception as error:  # noqa: BLE001
                    results.append(
                        {
                            "sample": sample,
                            "phrase": phrase_key,
                            "reference": reference_variant,
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

    print(f"[luxtts-denoise] report: {output_dir / 'summary.md'}")
    return 0 if all(result["ok"] for result in results) else 2


if __name__ == "__main__":
    raise SystemExit(main())
