#!/usr/bin/env python3
"""Small MLX-Audio TTS wrapper for PlushPal voice bakeoffs."""

from __future__ import annotations

import argparse
import random
import shutil
import sys
import tempfile
import traceback
from pathlib import Path


def _seed_everything(seed: int | None) -> None:
    if seed is None:
        return
    random.seed(seed)
    try:
        import numpy as np

        np.random.seed(seed)
    except Exception:
        pass
    try:
        import mlx.core as mx

        mx.random.seed(seed)
    except Exception:
        pass


def _run(args: argparse.Namespace) -> None:
    _seed_everything(args.seed)
    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model

    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    model = args.model
    if not args.strict:
        model = load_model(args.model, strict=False)

    with tempfile.TemporaryDirectory(prefix="plushpal-mlx-audio-") as tmp:
        tmp_path = Path(tmp)
        generate_audio(
            text=args.text,
            model=model,
            voice=args.voice,
            instruct=args.instruct,
            speed=args.speed,
            lang_code=args.lang_code,
            ref_audio=str(Path(args.reference).resolve()) if args.reference else None,
            ref_text=args.reference_text,
            stt_model=None,
            output_path=str(tmp_path),
            file_prefix="preview",
            audio_format="wav",
            join_audio=True,
            play=False,
            verbose=True,
            temperature=args.temperature,
            max_tokens=args.max_tokens,
            cfg_scale=args.cfg_scale,
            ddpm_steps=args.ddpm_steps,
            top_p=args.top_p,
            top_k=args.top_k,
            repetition_penalty=args.repetition_penalty,
        )
        generated = tmp_path / "preview.wav"
        if not generated.exists():
            alternatives = sorted(tmp_path.glob("preview*.wav"))
            if alternatives:
                generated = alternatives[-1]
        if not generated.exists():
            raise FileNotFoundError(f"MLX-Audio did not create a WAV under {tmp_path}")
        shutil.copy2(generated, output)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run an MLX-Audio TTS model")
    parser.add_argument("--model", required=True)
    parser.add_argument("--reference")
    parser.add_argument("--reference-text")
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--voice")
    parser.add_argument("--instruct")
    parser.add_argument("--lang-code", default="en")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--max-tokens", type=int)
    parser.add_argument("--cfg-scale", type=float)
    parser.add_argument("--ddpm-steps", type=int)
    parser.add_argument("--top-p", type=float, default=0.9)
    parser.add_argument("--top-k", type=int, default=50)
    parser.add_argument("--repetition-penalty", type=float, default=1.1)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--strict", action="store_true", default=True)
    parser.add_argument("--non-strict", dest="strict", action="store_false")
    args = parser.parse_args()

    try:
        _run(args)
        return 0
    except Exception as exc:  # pragma: no cover - process wrapper
        print(f"mlx_audio_tts failed: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
