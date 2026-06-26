#!/usr/bin/env python3
"""Generate a focused Chatterbox tuning bakeoff for baby-puppy toy voices."""

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
DEFAULT_OUTPUT = ROOT / "test-artifacts" / "chatterbox-tuning-2026-06-20"
SAMPLES = ["Buddy", "Jenna", "Sheru"]
PHRASES = {
    "preview_baby": "Mmm... woof woof... hii tiny friend... we pway now?",
    "slow_baby": "Mmm... hii tiny friend... I am your baby puppy... can we pway... pwease?",
}


@dataclass(frozen=True)
class Variant:
    name: str
    mode: str
    ref_window: str
    exaggeration: float = 0.82
    cfg_weight: float = 0.30
    temperature: float = 0.76
    min_p: float = 0.03
    top_p: float = 0.92
    repetition_penalty: float = 1.15


VARIANTS = [
    Variant("direct_start10_baby", "direct", "start10", 0.84, 0.30, 0.76),
    Variant("direct_mid10_baby", "direct", "mid10", 0.84, 0.30, 0.76),
    Variant("direct_late10_baby", "direct", "late10", 0.84, 0.30, 0.76),
    Variant("vc_start10_baby", "vc", "start10", 0.74, 0.32, 0.72),
]


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 1_200) -> None:
    subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


def env(output_dir: Path) -> dict[str, str]:
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
    bundled_hf = ROOT / "dist/macos/PlushPal.app/Contents/Resources/model-cache/huggingface"
    if bundled_hf.exists():
        result.update(
            {
                "HF_HOME": str(bundled_hf),
                "TRANSFORMERS_CACHE": str(bundled_hf),
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
            }
        )
    return result


def convert_sample(sample: str, output_dir: Path) -> Path:
    source = ROOT / "audio-samples" / f"{sample}.m4a"
    if not source.is_file():
        raise FileNotFoundError(source)
    converted = output_dir / "sources" / f"{sample}.wav"
    converted.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            "/usr/bin/afconvert",
            "-f",
            "WAVE",
            "-d",
            "LEI16@24000",
            "-c",
            "1",
            str(source),
            str(converted),
        ],
        timeout=120,
    )
    return converted


def make_window(reference: Path, output_dir: Path, sample: str, window: str) -> Path:
    audio, sample_rate = sf.read(reference, always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    total = len(audio)
    frames = min(total, int(10.0 * sample_rate))
    if window == "mid10":
        start = max(0, (total - frames) // 2)
    elif window == "late10":
        start = max(0, total - frames)
    else:
        start = 0
    sliced = audio[start : start + frames]
    path = output_dir / "references" / sample / f"{window}.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, sliced, sample_rate)
    return path


def generate_direct(reference: Path, text: str, output: Path, variant: Variant, output_dir: Path) -> None:
    python = ROOT / ".venv-chatterbox/bin/python"
    script = ROOT / "tools/voice/chatterbox_tts.py"
    run(
        [
            str(python),
            str(script),
            "--engine",
            "standard",
            "--device",
            "cpu",
            "--exaggeration",
            str(variant.exaggeration),
            "--cfg-weight",
            str(variant.cfg_weight),
            "--temperature",
            str(variant.temperature),
            "--min-p",
            str(variant.min_p),
            "--top-p",
            str(variant.top_p),
            "--repetition-penalty",
            str(variant.repetition_penalty),
            "--reference",
            str(reference),
            "--output",
            str(output),
            "--text",
            text,
        ],
        env=env(output_dir),
        timeout=1_200,
    )


def generate_vc(reference: Path, text: str, output: Path, variant: Variant, output_dir: Path) -> None:
    python = ROOT / ".venv-chatterbox/bin/python"
    script = ROOT / "tools/voice/chatterbox_vc_tts.py"
    run(
        [
            str(python),
            str(script),
            "--device",
            "cpu",
            "--target-reference",
            str(reference),
            "--output",
            str(output),
            "--text",
            text,
            "--exaggeration",
            str(variant.exaggeration),
            "--cfg-weight",
            str(variant.cfg_weight),
            "--temperature",
            str(variant.temperature),
            "--min-p",
            str(variant.min_p),
            "--top-p",
            str(variant.top_p),
            "--repetition-penalty",
            str(variant.repetition_penalty),
        ],
        env=env(output_dir),
        timeout=1_500,
    )


def duration(path: Path) -> float:
    info = sf.info(path)
    return float(info.frames) / float(info.samplerate)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run focused Chatterbox baby-puppy tuning bakeoff")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--samples", nargs="+", default=SAMPLES)
    parser.add_argument("--keep-going", action="store_true", default=True)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    converted = {sample: convert_sample(sample, output_dir) for sample in args.samples}
    windows = {
        sample: {
            window: make_window(converted[sample], output_dir, sample, window)
            for window in ["start10", "mid10", "late10"]
        }
        for sample in args.samples
    }

    results: list[dict[str, object]] = []
    for sample in args.samples:
        for phrase_key, text in PHRASES.items():
            for variant in VARIANTS:
                output = output_dir / sample / phrase_key / f"{variant.name}.wav"
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.monotonic()
                try:
                    print(f"[chatterbox-tune] {sample} {phrase_key} {variant.name}", flush=True)
                    reference = windows[sample][variant.ref_window]
                    if variant.mode == "vc":
                        generate_vc(reference, text, output, variant, output_dir)
                    else:
                        generate_direct(reference, text, output, variant, output_dir)
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
                except Exception as error:  # noqa: BLE001 - continue by design
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
                        break
                finally:
                    write_report(output_dir, results)
    print(f"[chatterbox-tune] report: {output_dir / 'summary.md'}")
    return 0 if all(result["ok"] for result in results) else 2


def write_report(output_dir: Path, results: list[dict[str, object]]) -> None:
    (output_dir / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    lines = [
        "# Chatterbox baby-puppy tuning bakeoff",
        "",
        "Target: not a normal 5-year-old voice; a 1-2-year-old-ish pretend puppy toy character.",
        "",
        "Listen for:",
        "",
        "- tiny baby-puppy tone",
        "- slower pretend-play cadence",
        "- soft/round phonemes",
        "- matching vibe from the uploaded sample",
        "- avoiding grown-up child voice",
        "",
        "Variants:",
        "",
        "- `direct_start10_baby`: direct Chatterbox clone using first 10 seconds of the sample.",
        "- `direct_mid10_baby`: direct Chatterbox clone using middle 10 seconds.",
        "- `direct_late10_baby`: direct Chatterbox clone using final 10 seconds.",
        "- `vc_start10_baby`: default Chatterbox TTS, then Chatterbox voice-conversion into first 10 seconds of sample.",
        "",
        "| sample | phrase | variant | status | render seconds | audio duration | file | notes |",
        "|---|---|---:|---|---:|---:|---|---|",
    ]
    for result in results:
        status = "ok" if result["ok"] else "failed"
        lines.append(
            f"| {result['sample']} | {result['phrase']} | {result['variant']} | {status} | "
            f"{result['seconds']} | {result['duration'] or ''} | {result['file']} | "
            f"{str(result['message']).replace('|', '/')} |"
        )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
