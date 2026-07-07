#!/usr/bin/env python3
"""Local Whisper speech-to-text wrapper for ToyTalk Hub.

The Hub invokes this script as a tiny CLI:

    whisper_transcribe.py /path/to/input.wav

It prints only the final transcript to stdout. Logs and model progress go to
stderr so the Hub can safely treat stdout as the transcript protocol.
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from pathlib import Path


def _transcribe(input_wav: Path, model_name: str, device: str) -> str:
    if not input_wav.is_file():
        raise FileNotFoundError(input_wav)
    if input_wav.stat().st_size > 12 * 1024 * 1024:
        raise ValueError("input WAV is too large")

    # Transformers uses stdout in a few paths. Keep stdout reserved for the
    # final transcript expected by the Rust Hub wrapper.
    protocol_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        import numpy as np
        import torch
        from scipy.io import wavfile
        from transformers import pipeline

        if device == "auto":
            if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
                device_arg: str | int = "mps"
            elif torch.cuda.is_available():
                device_arg = 0
            else:
                device_arg = -1
        elif device == "cpu":
            device_arg = -1
        else:
            device_arg = device

        transcriber = pipeline(
            "automatic-speech-recognition",
            model=model_name,
            device=device_arg,
        )
        sample_rate, samples = wavfile.read(input_wav)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        if samples.dtype.kind in {"i", "u"}:
            peak = float(np.iinfo(samples.dtype).max)
            samples = samples.astype(np.float32) / peak
        else:
            samples = samples.astype(np.float32)
        result = transcriber({"sampling_rate": int(sample_rate), "raw": samples})
    finally:
        sys.stdout = protocol_stdout

    if isinstance(result, dict):
        text = str(result.get("text") or "")
    else:
        text = str(result)
    return " ".join(text.strip().split())


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe a WAV locally with Whisper")
    parser.add_argument("input_wav", nargs="?")
    parser.add_argument("--model", default=os.environ.get("PLUSHPAL_STT_MODEL", "openai/whisper-base"))
    parser.add_argument("--device", default=os.environ.get("PLUSHPAL_STT_DEVICE", "auto"))
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()

    try:
        if args.healthcheck:
            import numpy  # noqa: F401
            import scipy  # noqa: F401
            import torch  # noqa: F401
            from transformers import pipeline  # noqa: F401

            return 0
        if not args.input_wav:
            raise ValueError("input WAV path is required")
        transcript = _transcribe(Path(args.input_wav).resolve(), args.model, args.device)
        if not transcript:
            raise ValueError("empty transcript")
        print(transcript)
        return 0
    except Exception as exc:  # pragma: no cover - process boundary
        print(f"whisper_transcribe failed: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
