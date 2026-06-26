#!/usr/bin/env python3
"""Local Chatterbox voice-cloning bridge for PlushPal.

This script is intentionally small and process-oriented so the Rust desktop
host can keep all uploaded voice samples encrypted at rest, decrypt a reference
clip only into a short-lived local temp file, and ask a local model runtime to
emit a WAV without sending voice data to a network service.
"""

from __future__ import annotations

import argparse
import sys
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


def _load_model(engine: str, device: str):
    if engine == "turbo":
        from chatterbox.tts_turbo import ChatterboxTurboTTS

        return ChatterboxTurboTTS.from_pretrained(device=device)
    if engine == "multilingual":
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS

        return ChatterboxMultilingualTTS.from_pretrained(device=device)
    from chatterbox.tts import ChatterboxTTS

    return ChatterboxTTS.from_pretrained(device=device)


def _generate(args: argparse.Namespace) -> None:
    import torchaudio as ta

    reference = Path(args.reference)
    output = Path(args.output)
    if not reference.is_file():
        raise FileNotFoundError(f"reference audio does not exist: {reference}")
    output.parent.mkdir(parents=True, exist_ok=True)

    device = _device(args.device)
    model = _load_model(args.engine, device)
    kwargs = {"text": args.text, "audio_prompt_path": str(reference)}
    if args.engine == "multilingual":
        kwargs["language_id"] = args.language
    if args.engine != "turbo":
        kwargs["exaggeration"] = args.exaggeration
        kwargs["cfg_weight"] = args.cfg_weight
        kwargs["temperature"] = args.temperature
        kwargs["min_p"] = args.min_p
        kwargs["top_p"] = args.top_p
        kwargs["repetition_penalty"] = args.repetition_penalty
    wav = model.generate(**kwargs)
    ta.save(str(output), wav, model.sr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run local Chatterbox TTS")
    parser.add_argument("--healthcheck", action="store_true")
    parser.add_argument("--engine", choices=["standard", "turbo", "multilingual"], default="standard")
    parser.add_argument("--device", default="auto", help="auto, cpu, mps, or cuda")
    parser.add_argument("--language", default="en")
    parser.add_argument("--exaggeration", type=float, default=0.68)
    parser.add_argument("--cfg-weight", type=float, default=0.45)
    parser.add_argument("--temperature", type=float, default=0.68)
    parser.add_argument("--min-p", type=float, default=0.05)
    parser.add_argument("--top-p", type=float, default=0.90)
    parser.add_argument("--repetition-penalty", type=float, default=1.2)
    parser.add_argument("--reference")
    parser.add_argument("--output")
    parser.add_argument("--text")
    args = parser.parse_args()

    try:
        if args.healthcheck:
            _device(args.device)
            _load_model(args.engine, _device(args.device))
            return 0
        if not args.reference or not args.output or not args.text:
            parser.error("--reference, --output, and --text are required unless --healthcheck is used")
        _generate(args)
        return 0
    except Exception as exc:  # pragma: no cover - surfaced to Rust host logs
        print(f"chatterbox_tts failed: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
