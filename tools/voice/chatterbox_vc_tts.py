#!/usr/bin/env python3
"""Generate speech, then run Chatterbox voice conversion to a target sample."""

from __future__ import annotations

import argparse
import tempfile
import traceback
from pathlib import Path


def _device(requested: str) -> str:
    if requested != "auto":
        return requested
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Chatterbox TTS followed by Chatterbox VC")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--target-reference", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--exaggeration", type=float, default=0.72)
    parser.add_argument("--cfg-weight", type=float, default=0.35)
    parser.add_argument("--temperature", type=float, default=0.72)
    parser.add_argument("--min-p", type=float, default=0.03)
    parser.add_argument("--top-p", type=float, default=0.92)
    parser.add_argument("--repetition-penalty", type=float, default=1.15)
    args = parser.parse_args()

    try:
        import torch
        import torchaudio as ta
        from chatterbox.tts import ChatterboxTTS
        from chatterbox.vc import ChatterboxVC

        torch.manual_seed(args.seed)
        device = _device(args.device)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)

        with tempfile.TemporaryDirectory(prefix="plushpal-chatterbox-vc-") as temp_dir:
            source_path = Path(temp_dir) / "source.wav"

            tts = ChatterboxTTS.from_pretrained(device=device)
            source_wav = tts.generate(
                text=args.text,
                exaggeration=args.exaggeration,
                cfg_weight=args.cfg_weight,
                temperature=args.temperature,
                min_p=args.min_p,
                top_p=args.top_p,
                repetition_penalty=args.repetition_penalty,
            )
            ta.save(str(source_path), source_wav, tts.sr)

            vc = ChatterboxVC.from_pretrained(device=device)
            converted = vc.generate(str(source_path), target_voice_path=args.target_reference)
            ta.save(str(output), converted, vc.sr)

        return 0
    except Exception as exc:  # pragma: no cover - surfaced in bakeoff logs
        print(f"chatterbox_vc_tts failed: {exc}")
        traceback.print_exc()
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
