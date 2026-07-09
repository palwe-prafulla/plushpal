# Known limitations

Last updated: 2026-07-08

ToyTalk is public and buildable, but it is still an MVP/prototype. The core
Hub-backed architecture is implemented for paired product usage, including a
paired-device registry and parent-gated revocation. The Hub now packages a
local Whisper STT fallback endpoint, and Android/iPhone can record bounded
local WAV fallback clips for that endpoint. Local browser/Mac WebKit clients
can also record bounded WAV fallback clips for Hub STT when browser microphone
capture is available. Per-client encrypted Hub data stores are implemented on
top of stable client identity. Local-first AI mode is implemented with signed
Google Gemma GGUF manifests and Hub-side model recommendation, but needs broader
safety/performance QA before product-release claims.
The Hub also prepares a small local current-info router using MiniLM-L6
embeddings plus a ToyTalk classifier. It runs on every child question so
current/live questions can be handled without silently returning stale model
memory.

## Architecture limitations

- Paired product usage routes durable state, provider calls, guardrails, and
  business logic through ToyTalk Hub.
- External clients are UI shells: they keep stable identity, pairing/session
  info, UI preference, permissions, and temporary media-helper state only. Demo
  and mock behavior lives in the Hub runtime, not in client-owned family stores.
- Remote browser clients are intentionally out of scope. Browser support is
  local-only on the same machine running the Hub.
- Windows/Linux Hub launchers are future work.

## Platform limitations

- The full local voice path is currently validated on Apple Silicon macOS.
- Android is the primary tested external native client.
- The iPhone app builds and launches in simulator, but physical-device install
  requires Apple signing/provisioning.
- Mac native client support exists through the same shared Flutter client stack;
  microphone capture depends on macOS/WebKit microphone permission and browser
  audio APIs.
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

- Android/iPhone STT paths enforce on-device recognition when available.
- Local browser/Mac WebKit clients use bounded microphone capture and the Hub
  local STT endpoint when mic APIs are available; typed chat remains the
  fallback if mic capture is blocked.
- Hub local STT fallback is prepared by first-run setup through a
  Python/Transformers `openai/whisper-base` wrapper and health-checked by the
  Hub launcher; it is still heavier than the future `whisper.cpp` runtime
  target.
- Fully local mode defaults to the recommended Gemma E4B GGUF model on current
  Apple Silicon Macs, with larger Gemma tiers treated as optional/manual
  experiments until broader latency and safety testing is complete.
- Current/live question detection is implemented locally. Parent-controlled web
  search can let Gemini/OpenAI use their native web-search tools only when the
  classifier says a turn needs latest information. Local AI normally asks the
  child to check current/live questions with a grown-up rather than guessing
  from stale model memory. A hidden Brave Search env hook exists for advanced
  Local AI evidence experiments, but it is not part of the normal parent UX.
- Cloud AI mode requires a parent-provided Gemini/OpenAI key, stored by the
  Hub and never returned to clients.
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
