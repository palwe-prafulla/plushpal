#!/usr/bin/env python3
"""Denoise PlushPal reference recordings without changing pitch or timing."""

from __future__ import annotations

import argparse
from pathlib import Path

import noisereduce as nr
import numpy as np
import soundfile as sf
from scipy import signal


PRESETS = {
    "mild": {
        "prop_decrease": 0.45,
        "stationary": True,
        "highpass_hz": 70.0,
        "noise_seconds": 0.8,
    },
    "medium": {
        "prop_decrease": 0.65,
        "stationary": True,
        "highpass_hz": 85.0,
        "noise_seconds": 1.2,
    },
    "strong": {
        "prop_decrease": 0.82,
        "stationary": True,
        "highpass_hz": 100.0,
        "noise_seconds": 1.5,
    },
}


def _mono_float(audio: np.ndarray) -> np.ndarray:
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio.astype(np.float32, copy=False)


def _highpass(audio: np.ndarray, sample_rate: int, cutoff_hz: float) -> np.ndarray:
    if cutoff_hz <= 0:
        return audio
    sos = signal.butter(2, cutoff_hz, btype="highpass", fs=sample_rate, output="sos")
    return signal.sosfiltfilt(sos, audio).astype(np.float32)


def _normalize(audio: np.ndarray, peak: float = 0.92) -> np.ndarray:
    max_abs = float(np.max(np.abs(audio))) if audio.size else 0.0
    if max_abs <= 1e-8:
        return audio
    return (audio * min(1.0, peak / max_abs)).astype(np.float32)


def denoise(input_path: Path, output_path: Path, preset: str) -> None:
    settings = PRESETS[preset]
    audio, sample_rate = sf.read(input_path, always_2d=False)
    audio = _mono_float(audio)
    audio = _highpass(audio, sample_rate, settings["highpass_hz"])

    noise_frames = int(settings["noise_seconds"] * sample_rate)
    noise_clip = audio[:noise_frames] if noise_frames > 0 else None
    cleaned = nr.reduce_noise(
        y=audio,
        sr=sample_rate,
        y_noise=noise_clip,
        stationary=settings["stationary"],
        prop_decrease=settings["prop_decrease"],
        n_jobs=1,
    ).astype(np.float32)
    cleaned = _normalize(cleaned)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(output_path, cleaned, sample_rate, subtype="PCM_16")


def main() -> int:
    parser = argparse.ArgumentParser(description="Denoise a voice reference WAV")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preset", choices=sorted(PRESETS), default="medium")
    args = parser.parse_args()

    denoise(args.input, args.output, args.preset)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
