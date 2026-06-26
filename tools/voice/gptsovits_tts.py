#!/usr/bin/env python3
"""Small GPT-SoVITS inference wrapper for PlushPal voice bakeoffs.

This is intentionally not part of the app runtime yet. It lets us evaluate
GPT-SoVITS against the same local toy samples before deciding whether it is
worth productizing.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import yaml


ROOT = Path(__file__).resolve().parents[2]
GPT_SOVITS_ROOT = ROOT / "third_party" / "GPT-SoVITS"


def write_config(device: str, version: str) -> Path:
    pretrained = GPT_SOVITS_ROOT / "GPT_SoVITS" / "pretrained_models"
    if version != "v2":
        raise ValueError("This bakeoff wrapper currently supports GPT-SoVITS v2 only.")

    config = {
        "custom": {
            "bert_base_path": str(pretrained / "chinese-roberta-wwm-ext-large"),
            "cnhuhbert_base_path": str(pretrained / "chinese-hubert-base"),
            "device": device,
            "is_half": False,
            "t2s_weights_path": str(
                pretrained
                / "gsv-v2final-pretrained"
                / "s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt"
            ),
            "version": "v2",
            "vits_weights_path": str(pretrained / "gsv-v2final-pretrained" / "s2G2333k.pth"),
        }
    }
    handle = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8")
    with handle:
        yaml.safe_dump(config, handle)
    return Path(handle.name)


def validate_models() -> None:
    required = [
        GPT_SOVITS_ROOT / "GPT_SoVITS" / "pretrained_models" / "chinese-roberta-wwm-ext-large",
        GPT_SOVITS_ROOT / "GPT_SoVITS" / "pretrained_models" / "chinese-hubert-base",
        GPT_SOVITS_ROOT
        / "GPT_SoVITS"
        / "pretrained_models"
        / "gsv-v2final-pretrained"
        / "s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt",
        GPT_SOVITS_ROOT
        / "GPT_SoVITS"
        / "pretrained_models"
        / "gsv-v2final-pretrained"
        / "s2G2333k.pth",
    ]
    missing = [path for path in required if not path.exists()]
    if missing:
        joined = "\n".join(str(path) for path in missing)
        raise FileNotFoundError(f"GPT-SoVITS pretrained files are missing:\n{joined}")


def prepare_reference(reference: Path) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    """Return a GPT-SoVITS-compatible 3-10s reference file.

    GPT-SoVITS rejects longer references. The PlushPal samples are intentionally
    longer, so for bakeoffs we extract the first high-energy ~9 second window
    into a temporary WAV and leave the original file untouched.
    """

    audio, sample_rate = sf.read(reference, always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    duration = len(audio) / sample_rate
    if 3.0 <= duration <= 10.0:
        return reference, None

    target_seconds = 9.0
    target_frames = min(len(audio), int(target_seconds * sample_rate))
    absolute = np.abs(audio)
    peak = float(absolute.max(initial=0.0))
    start_frame = 0
    if peak > 0:
        threshold = peak * 0.03
        active = np.flatnonzero(absolute > threshold)
        if active.size:
            start_frame = max(0, int(active[0]) - int(0.25 * sample_rate))
    if start_frame + target_frames > len(audio):
        start_frame = max(0, len(audio) - target_frames)
    trimmed = audio[start_frame : start_frame + target_frames]
    if len(trimmed) < int(3.0 * sample_rate):
        raise ValueError(f"Reference audio is too short after trimming: {reference}")

    temp_dir = tempfile.TemporaryDirectory(prefix="plushpal-gptsovits-ref-")
    trimmed_path = Path(temp_dir.name) / "reference_9s.wav"
    sf.write(trimmed_path, trimmed, sample_rate)
    return trimmed_path, temp_dir


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate one GPT-SoVITS sample")
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--prompt-text", default="")
    parser.add_argument("--prompt-lang", default="en")
    parser.add_argument("--text", required=True)
    parser.add_argument("--text-lang", default="en")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--version", default="v2")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--top-k", type=int, default=15)
    parser.add_argument("--top-p", type=float, default=1.0)
    parser.add_argument("--temperature", type=float, default=0.85)
    parser.add_argument("--repetition-penalty", type=float, default=1.35)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    validate_models()
    os.chdir(GPT_SOVITS_ROOT)
    sys.path.insert(0, str(GPT_SOVITS_ROOT))
    sys.path.insert(0, str(GPT_SOVITS_ROOT / "GPT_SoVITS"))

    from GPT_SoVITS.TTS_infer_pack.TTS import TTS, TTS_Config  # noqa: PLC0415

    config_path = write_config(args.device, args.version)
    reference_path, reference_temp = prepare_reference(args.reference.resolve())
    try:
        tts = TTS(TTS_Config(str(config_path)))
        chunks: list[np.ndarray] = []
        sample_rate = 32000
        for rate, audio in tts.run(
            {
                "text": args.text,
                "text_lang": args.text_lang,
                "ref_audio_path": str(reference_path),
                "prompt_text": args.prompt_text,
                "prompt_lang": args.prompt_lang,
                "top_k": args.top_k,
                "top_p": args.top_p,
                "temperature": args.temperature,
                "text_split_method": "cut5",
                "batch_size": 1,
                "speed_factor": args.speed,
                "fragment_interval": 0.35,
                "seed": args.seed,
                "parallel_infer": False,
                "repetition_penalty": args.repetition_penalty,
                "streaming_mode": False,
            }
        ):
            sample_rate = rate
            chunks.append(audio)
        if not chunks:
            raise RuntimeError("GPT-SoVITS returned no audio.")
        combined = np.concatenate(chunks)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        sf.write(args.output, combined, sample_rate)
    finally:
        config_path.unlink(missing_ok=True)
        if reference_temp is not None:
            reference_temp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
