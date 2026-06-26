#!/usr/bin/env python3
"""Generate local voice-cloning bakeoff artifacts for PlushPal.

This is intentionally outside the app runtime. It compares candidate engines
against the same toy samples and generated phrases, then writes WAV files and a
small markdown report for human listening.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "test-artifacts" / "voice-bakeoff-2026-06-20"
DEFAULT_PHRASES = {
    "preview": "Woof woof! Hi friend, let us play!",
    "slow_puppy": "Ohh... hi tiny friend... I am your puppy... can we play?",
}
SAMPLES = ["Buddy", "Jenna", "Sheru"]
DEFAULT_REFERENCE_TEXT = {
    # These are intentionally approximate because the current samples are
    # pretend-play character recordings, not scripted read-aloud clips. Supplying
    # something non-empty keeps F5-TTS away from its ASR path, which is fragile on
    # stock macOS without a full shared FFmpeg install.
    "Buddy": "Woof woof, I am Buddy, a tiny puppy toy, and I want to play.",
    "Jenna": "Hi hi, I am Jenna, a little puppy toy voice, and I am ready to play.",
    "Sheru": "Woof woof, I am Sheru, your tiny puppy friend, and I can play with you.",
}


@dataclass(frozen=True)
class RunResult:
    engine: str
    sample: str
    phrase: str
    ok: bool
    output: str | None
    seconds: float
    message: str


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 900) -> None:
    subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=timeout)


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


def chatterbox_env(output_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
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
        env.update(
            {
                "HF_HOME": str(bundled_hf),
                "TRANSFORMERS_CACHE": str(bundled_hf),
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
            }
        )
    return env


def generate_chatterbox(reference: Path, text: str, output: Path, output_dir: Path) -> None:
    python = ROOT / ".venv-chatterbox/bin/python"
    if not python.exists():
        python = ROOT / "dist/macos/PlushPal.app/Contents/Resources/python/bin/python3"
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
            "0.68",
            "--cfg-weight",
            "0.45",
            "--temperature",
            "0.68",
            "--min-p",
            "0.05",
            "--top-p",
            "0.90",
            "--repetition-penalty",
            "1.2",
            "--reference",
            str(reference),
            "--output",
            str(output),
            "--text",
            text,
        ],
        env=chatterbox_env(output_dir),
        timeout=900,
    )


def f5_env(output_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    f5_bin = ROOT / ".venv-f5tts/bin"
    env.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "XDG_CACHE_HOME": str(output_dir / "cache"),
            "NUMBA_CACHE_DIR": str(output_dir / "cache" / "numba"),
            "MPLCONFIGDIR": str(output_dir / "cache" / "matplotlib"),
            "PATH": f"{f5_bin}:{env.get('PATH', '')}",
        }
    )
    # Let F5 download/cache into the bakeoff folder instead of app resources.
    env["HF_HOME"] = str(output_dir / "cache" / "huggingface")
    return env


def generate_f5(
    reference: Path,
    reference_text: str,
    text: str,
    output: Path,
    output_dir: Path,
) -> None:
    cli = ROOT / ".venv-f5tts/bin/f5-tts_infer-cli"
    if not cli.exists():
        raise FileNotFoundError(
            f"{cli} is missing. Install with: "
            "dist/macos/PlushPal.app/Contents/Resources/python/bin/python3 -m venv .venv-f5tts "
            "&& .venv-f5tts/bin/python -m pip install f5-tts"
        )
    temporary = output_dir / "tmp" / "f5"
    temporary.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    generated_name = output.name
    run(
        [
            str(cli),
            "--model",
            "F5TTS_v1_Base",
            "--ref_audio",
            str(reference),
            "--ref_text",
            reference_text,
            "--gen_text",
            text,
            "--output_dir",
            str(temporary),
            "--output_file",
            generated_name,
            "--speed",
            "0.88",
            "--nfe_step",
            "32",
            "--cfg_strength",
            "2.0",
            "--device",
            "cpu",
        ],
        env=f5_env(output_dir),
        timeout=1_800,
    )
    candidates = sorted(temporary.rglob(generated_name), key=lambda path: path.stat().st_mtime)
    if not candidates:
        candidates = sorted(temporary.rglob("*.wav"), key=lambda path: path.stat().st_mtime)
    if not candidates:
        raise FileNotFoundError(f"F5 did not create a WAV in {temporary}")
    shutil.copy2(candidates[-1], output)


def gptsovits_env(output_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    gsv_bin = ROOT / ".venv-gptsovits/bin"
    f5_bin = ROOT / ".venv-f5tts/bin"
    env.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "XDG_CACHE_HOME": str(output_dir / "cache"),
            "NUMBA_CACHE_DIR": str(output_dir / "cache" / "numba"),
            "MPLCONFIGDIR": str(output_dir / "cache" / "matplotlib"),
            "PATH": f"{gsv_bin}:{f5_bin}:{env.get('PATH', '')}",
        }
    )
    env["HF_HOME"] = str(output_dir / "cache" / "huggingface")
    return env


def generate_gptsovits(
    reference: Path,
    reference_text: str,
    text: str,
    output: Path,
    output_dir: Path,
) -> None:
    python = ROOT / ".venv-gptsovits/bin/python"
    if not python.exists():
        raise FileNotFoundError(
            f"{python} is missing. Install GPT-SoVITS dependencies before running this engine."
        )
    script = ROOT / "tools/voice/gptsovits_tts.py"
    run(
        [
            str(python),
            str(script),
            "--reference",
            str(reference),
            "--prompt-text",
            reference_text,
            "--prompt-lang",
            "en",
            "--text",
            text,
            "--text-lang",
            "en",
            "--output",
            str(output),
            "--device",
            os.environ.get("PLUSHPAL_GPTSOVITS_DEVICE", "cpu"),
            "--speed",
            os.environ.get("PLUSHPAL_GPTSOVITS_SPEED", "1.0"),
            "--temperature",
            os.environ.get("PLUSHPAL_GPTSOVITS_TEMPERATURE", "0.85"),
            "--seed",
            os.environ.get("PLUSHPAL_GPTSOVITS_SEED", "42"),
        ],
        env=gptsovits_env(output_dir),
        timeout=2_400,
    )


def openvoice_env(output_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    ov_bin = ROOT / ".venv-openvoice/bin"
    env.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "XDG_CACHE_HOME": str(output_dir / "cache"),
            "NUMBA_CACHE_DIR": str(output_dir / "cache" / "numba"),
            "MPLCONFIGDIR": str(output_dir / "cache" / "matplotlib"),
            "PATH": f"{ov_bin}:{env.get('PATH', '')}",
        }
    )
    return env


def generate_openvoice(reference: Path, text: str, output: Path, output_dir: Path) -> None:
    python = ROOT / ".venv-openvoice/bin/python"
    if not python.exists():
        raise FileNotFoundError(
            f"{python} is missing. Install OpenVoice dependencies before running this engine."
        )
    script = ROOT / "tools/voice/openvoice_tts.py"
    run(
        [
            str(python),
            str(script),
            "--reference",
            str(reference),
            "--text",
            text,
            "--output",
            str(output),
            "--speaker",
            os.environ.get("PLUSHPAL_OPENVOICE_SPEAKER", "cheerful"),
            "--speed",
            os.environ.get("PLUSHPAL_OPENVOICE_SPEED", "0.92"),
            "--tau",
            os.environ.get("PLUSHPAL_OPENVOICE_TAU", "0.28"),
        ],
        env=openvoice_env(output_dir),
        timeout=900,
    )


def generate_placeholder(engine: str) -> None:
    raise RuntimeError(
        f"{engine} engine is not wired yet. This harness is ready for it, but "
        "the repo-specific setup still needs to be added after F5 is evaluated."
    )


def generate(
    engine: str,
    sample: str,
    reference: Path,
    text: str,
    output: Path,
    output_dir: Path,
) -> None:
    if engine == "chatterbox":
        generate_chatterbox(reference, text, output, output_dir)
    elif engine == "f5tts":
        generate_f5(reference, DEFAULT_REFERENCE_TEXT.get(sample, ""), text, output, output_dir)
    elif engine == "gpt-sovits":
        generate_gptsovits(reference, DEFAULT_REFERENCE_TEXT.get(sample, ""), text, output, output_dir)
    elif engine == "openvoice":
        generate_openvoice(reference, text, output, output_dir)
    elif engine in {"cosyvoice"}:
        generate_placeholder(engine)
    else:
        raise ValueError(f"unknown engine: {engine}")


def write_report(output_dir: Path, results: list[RunResult]) -> None:
    report = output_dir / "summary.md"
    data = output_dir / "summary.json"
    data.write_text(json.dumps([result.__dict__ for result in results], indent=2), encoding="utf-8")
    lines = [
        "# PlushPal voice bakeoff",
        "",
        "Listen for baby/toy character essence, not only speaker similarity:",
        "",
        "- tiny/baby-like pitch",
        "- pretend-play puppy cadence",
        "- slower pauses",
        "- breathy/playful tone",
        "- whether it still feels like Buddy/Jenna/Sheru rather than a generic child voice",
        "",
        "| sample | phrase | engine | status | seconds | file | notes |",
        "|---|---|---:|---|---:|---|---|",
    ]
    for result in results:
        file_cell = result.output or ""
        status = "ok" if result.ok else "failed"
        lines.append(
            f"| {result.sample} | {result.phrase} | {result.engine} | {status} | "
            f"{result.seconds:.1f} | {file_cell} | {result.message.replace('|', '/')} |"
        )
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run PlushPal local voice bakeoff")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--engines",
        nargs="+",
        default=["chatterbox", "f5tts"],
        help="Engines: chatterbox f5tts gpt-sovits openvoice cosyvoice",
    )
    parser.add_argument("--samples", nargs="+", default=SAMPLES)
    parser.add_argument(
        "--phrases",
        nargs="+",
        choices=sorted(DEFAULT_PHRASES),
        default=sorted(DEFAULT_PHRASES),
    )
    parser.add_argument("--keep-going", action="store_true", default=True)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    results: list[RunResult] = []
    converted = {sample: convert_sample(sample, output_dir) for sample in args.samples}
    for sample in args.samples:
        for phrase_key in args.phrases:
            text = DEFAULT_PHRASES[phrase_key]
            for engine in args.engines:
                output = output_dir / sample / phrase_key / f"{engine}.wav"
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.monotonic()
                try:
                    print(f"[bakeoff] {sample} {phrase_key} {engine}", flush=True)
                    generate(engine, sample, converted[sample], text, output, output_dir)
                    seconds = time.monotonic() - start
                    results.append(
                        RunResult(
                            engine=engine,
                            sample=sample,
                            phrase=phrase_key,
                            ok=True,
                            output=str(output),
                            seconds=seconds,
                            message="",
                        )
                    )
                except Exception as error:  # noqa: BLE001 - report and continue by design
                    seconds = time.monotonic() - start
                    results.append(
                        RunResult(
                            engine=engine,
                            sample=sample,
                            phrase=phrase_key,
                            ok=False,
                            output=None,
                            seconds=seconds,
                            message=str(error),
                        )
                    )
                    print(f"[bakeoff] failed: {sample} {phrase_key} {engine}: {error}", file=sys.stderr)
                    if not args.keep_going:
                        write_report(output_dir, results)
                        return 1
                finally:
                    write_report(output_dir, results)
    print(f"[bakeoff] report: {output_dir / 'summary.md'}")
    return 0 if all(result.ok for result in results) else 2


if __name__ == "__main__":
    raise SystemExit(main())
