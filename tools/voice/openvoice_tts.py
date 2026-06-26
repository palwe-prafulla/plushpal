#!/usr/bin/env python3
"""Small OpenVoice V1 wrapper for PlushPal voice bakeoffs."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import torch


ROOT = Path(__file__).resolve().parents[2]
OPENVOICE_ROOT = ROOT / "third_party" / "OpenVoice"


def prepare_reference(reference: Path) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    audio, sample_rate = sf.read(reference, always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    duration = len(audio) / sample_rate
    if 3.0 <= duration <= 20.0:
        return reference, None

    target_frames = min(len(audio), int(12.0 * sample_rate))
    absolute = np.abs(audio)
    peak = float(absolute.max(initial=0.0))
    start_frame = 0
    if peak > 0:
        active = np.flatnonzero(absolute > peak * 0.03)
        if active.size:
            start_frame = max(0, int(active[0]) - int(0.25 * sample_rate))
    if start_frame + target_frames > len(audio):
        start_frame = max(0, len(audio) - target_frames)
    trimmed = audio[start_frame : start_frame + target_frames]

    temp_dir = tempfile.TemporaryDirectory(prefix="plushpal-openvoice-ref-")
    trimmed_path = Path(temp_dir.name) / "reference.wav"
    sf.write(trimmed_path, trimmed, sample_rate)
    return trimmed_path, temp_dir


def validate_checkpoints() -> None:
    required = [
        OPENVOICE_ROOT / "checkpoints" / "base_speakers" / "EN" / "config.json",
        OPENVOICE_ROOT / "checkpoints" / "base_speakers" / "EN" / "checkpoint.pth",
        OPENVOICE_ROOT / "checkpoints" / "base_speakers" / "EN" / "en_default_se.pth",
        OPENVOICE_ROOT / "checkpoints" / "converter" / "config.json",
        OPENVOICE_ROOT / "checkpoints" / "converter" / "checkpoint.pth",
    ]
    missing = [path for path in required if not path.exists()]
    if missing:
        joined = "\n".join(str(path) for path in missing)
        raise FileNotFoundError(f"OpenVoice checkpoint files are missing:\n{joined}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate one OpenVoice V1 sample")
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--speaker", default="cheerful")
    parser.add_argument("--speed", type=float, default=0.92)
    parser.add_argument("--tau", type=float, default=0.28)
    args = parser.parse_args()

    validate_checkpoints()
    os.chdir(OPENVOICE_ROOT)
    sys.path.insert(0, str(OPENVOICE_ROOT))

    from openvoice.api import BaseSpeakerTTS, ToneColorConverter  # noqa: PLC0415

    device = "cpu"
    base_dir = OPENVOICE_ROOT / "checkpoints" / "base_speakers" / "EN"
    converter_dir = OPENVOICE_ROOT / "checkpoints" / "converter"
    reference_path, reference_temp = prepare_reference(args.reference.resolve())
    temp_dir = tempfile.TemporaryDirectory(prefix="plushpal-openvoice-src-")
    try:
        base_tts = BaseSpeakerTTS(str(base_dir / "config.json"), device=device)
        base_tts.load_ckpt(str(base_dir / "checkpoint.pth"))

        converter = ToneColorConverter(str(converter_dir / "config.json"), device=device)
        converter.load_ckpt(str(converter_dir / "checkpoint.pth"))

        target_se = converter.extract_se([str(reference_path)])
        source_se = torch.load(str(base_dir / "en_default_se.pth"), map_location=device).to(device)

        source_path = Path(temp_dir.name) / "source.wav"
        base_tts.tts(args.text, str(source_path), speaker=args.speaker, language="English", speed=args.speed)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        converter.convert(
            audio_src_path=str(source_path),
            src_se=source_se,
            tgt_se=target_se,
            output_path=str(args.output),
            tau=args.tau,
            message="PlushPal",
        )
    finally:
        temp_dir.cleanup()
        if reference_temp is not None:
            reference_temp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
