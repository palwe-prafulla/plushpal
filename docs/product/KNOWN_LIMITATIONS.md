# Known limitations

Last updated: 2026-06-26

PlushBuddy is public and buildable, but it is still an MVP/prototype. These are
the current important limitations.

## Platform limitations

- The full local voice path is currently validated on Apple Silicon macOS.
- The Android app is the primary MVP mobile surface.
- The iPhone app builds and launches in simulator, but physical-device install
  requires Apple signing/provisioning.
- Windows packaging is not the current validated product path.
- Browser local storage is not yet encrypted.

## Voice/model limitations

- LuxTTS gives the best current voice match, but it is not a polished commercial
  SDK.
- First setup can be large and slow because model/runtime dependencies need to
  be downloaded or packaged.
- Voice quality depends heavily on the sample quality, recording noise, and toy
  voice style.
- Voice synthesis latency can still be noticeable, especially for longer text.
- The current production path expects the MacStation voice appliance to be
  available for voice profile creation and TTS playback.

## Reasoning limitations

- Cloud reasoning requires a parent-provided Gemini/OpenAI API key.
- Prompt guardrails reduce risk but are not a complete safety system.
- Provider behavior can change over time.
- Fully local mobile reasoning is not part of the current MVP.

## Developer/clone limitations

- `make public-artifacts` needs a reasonably complete macOS development setup.
- Android artifacts require Android SDK/NDK and `cargo-ndk`.
- iOS artifacts require full Xcode and CocoaPods.
- Full LuxTTS E2E is intentionally not run in GitHub CI because it is heavy and
  model/runtime dependent.
- `PLUSHPAL_RUNTIME_MODE=demo` / `make run-demo` is a synthetic flow-test mode
  only. It does not clone voices, does not call Gemini/OpenAI, and should not
  be used to judge product voice quality.

## Public repository policy

This repository is public for learning, portfolio, and reference purposes. It is
not currently accepting external pull requests or direct contributions. Forks
are welcome under the license terms.
