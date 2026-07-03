# Known limitations

Last updated: 2026-07-02

PlushBuddy is public and buildable, but it is still an MVP/prototype. The Hub
architecture described in the current system design is the vNext target and is
not fully implemented in the prerelease yet.

## Architecture limitations

- The current prerelease still contains legacy client-owned state/reasoning
  paths.
- The target design moves durable state, provider calls, guardrails, and
  business logic into PlushBuddy Hub.
- Remote browser clients are intentionally out of scope. Browser support is
  local-only on the same machine running the Hub.
- Windows/Linux Hub launchers are future work.

## Platform limitations

- The full local voice path is currently validated on Apple Silicon macOS.
- Android is the primary tested external native client.
- The iPhone app builds and launches in simulator, but physical-device install
  requires Apple signing/provisioning.
- Mac native client support exists, but the Hub migration must make it a thin
  voice-first client.
- Windows packaging is not the current validated product path.

## Voice/model limitations

- LuxTTS gives the best current voice match, but it is not a polished commercial
  SDK.
- First setup can be large and slow because model/runtime dependencies need to
  be downloaded or packaged.
- Voice quality depends heavily on sample quality, recording noise, and toy
  voice style.
- Voice synthesis latency can still be noticeable, especially for longer text.
- Hub must keep the host machine awake while active. The display may sleep, but
  the system should not suspend.

## STT/reasoning limitations

- Platform default STT APIs are not automatically local-only. The target design
  requires verified on-device STT or Hub local STT fallback.
- Hub local STT fallback is not yet fully productized.
- Fully local mode requires a local LLM runtime and model recommendation flow.
- Cloud LLM mode still requires a parent-provided Gemini/OpenAI key.
- Prompt guardrails reduce risk but are not a complete safety system.

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
