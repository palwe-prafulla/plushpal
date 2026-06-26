#!/usr/bin/env python3
"""Small LuxTTS wrapper for PlushPal voice bakeoffs."""

from __future__ import annotations

import argparse
import random
import sys
import traceback
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LUX_ROOT_CANDIDATES = [
    ROOT / "third_party" / "LuxTTS",
    Path(__file__).resolve().parents[1] / "third_party" / "LuxTTS",
]
LUX_ROOT = next((path for path in LUX_ROOT_CANDIDATES if path.is_dir()), LUX_ROOT_CANDIDATES[0])


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
        import torch

        torch.manual_seed(seed)
        if torch.backends.mps.is_available():
            torch.mps.manual_seed(seed)
    except Exception:
        pass


def _run(args: argparse.Namespace) -> None:
    _seed_everything(args.seed)
    sys.path.insert(0, str(LUX_ROOT))

    import librosa
    import soundfile as sf
    import torch
    import zipvoice.luxvoice as luxvoice
    from huggingface_hub import snapshot_download
    from zipvoice.luxvoice import LuxTTS
    from zipvoice.utils.infer import rms_norm

    if args.healthcheck:
        snapshot_download(args.model)
        snapshot_download("openai/whisper-base")
        return

    @torch.inference_mode()
    def process_audio_with_long_prompt_support(
        audio,
        transcriber,
        tokenizer,
        feature_extractor,
        device,
        target_rms=0.1,
        duration=4,
        feat_scale=0.1,
    ):
        prompt_wav, _ = librosa.load(audio, sr=24000, duration=duration)
        prompt_wav2, _ = librosa.load(audio, sr=16000, duration=duration)
        transcription_kwargs = {"return_timestamps": True} if duration and duration > 30 else {}
        prompt_text = transcriber(prompt_wav2, **transcription_kwargs)["text"]
        print(prompt_text)

        prompt_wav_tensor = torch.from_numpy(prompt_wav).unsqueeze(0)
        prompt_wav_tensor, prompt_rms = rms_norm(prompt_wav_tensor, target_rms)

        prompt_features = feature_extractor.extract(
            prompt_wav_tensor, sampling_rate=24000
        ).to(device)
        prompt_features = prompt_features.unsqueeze(0) * feat_scale
        prompt_features_lens = torch.tensor([prompt_features.size(1)], device=device)
        prompt_tokens = tokenizer.texts_to_token_ids([prompt_text])
        return prompt_tokens, prompt_features_lens, prompt_features, prompt_rms

    luxvoice.process_audio = process_audio_with_long_prompt_support

    if not args.reference or not args.output or not args.text:
        raise ValueError("--reference, --text, and --output are required unless --healthcheck is used")

    reference = Path(args.reference).resolve()
    output = Path(args.output).resolve()
    if not reference.is_file():
        raise FileNotFoundError(reference)
    output.parent.mkdir(parents=True, exist_ok=True)

    model = LuxTTS(args.model, device=args.device, threads=args.threads)
    encoded_prompt = model.encode_prompt(
        str(reference),
        duration=args.ref_duration,
        rms=args.rms,
    )
    final_wav = model.generate_speech(
        args.text,
        encoded_prompt,
        num_steps=args.num_steps,
        t_shift=args.t_shift,
        speed=args.speed,
        return_smooth=args.return_smooth,
    )
    final_wav = final_wav.detach().cpu().numpy().squeeze()
    sf.write(str(output), final_wav, 48_000)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run LuxTTS")
    parser.add_argument("--model", default="YatharthS/LuxTTS")
    parser.add_argument("--device", default="mps")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--reference")
    parser.add_argument("--text")
    parser.add_argument("--output")
    parser.add_argument("--ref-duration", type=float, default=10.0)
    parser.add_argument("--rms", type=float, default=0.01)
    parser.add_argument("--num-steps", type=int, default=4)
    parser.add_argument("--t-shift", type=float, default=0.9)
    parser.add_argument("--speed", type=float, default=0.92)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--return-smooth", action="store_true")
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()

    try:
        _run(args)
        return 0
    except Exception as exc:  # pragma: no cover - process wrapper
        print(f"luxtts_tts failed: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
