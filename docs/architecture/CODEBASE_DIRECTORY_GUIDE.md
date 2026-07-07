# ToyTalk codebase directory guide

Last updated: 2026-07-05

This guide maps the current Hub-centric ToyTalk codebase. The public product
name is **ToyTalk Hub**. Some source paths still contain the historical
`macstation` implementation name; those paths are the Hub backend until they are
renamed.

## 1. Product mental model

```text
ToyTalk Hub
  macOS setup app + Rust backend + SQLCipher stores + models

Thin clients
  Android app
  iPhone app
  Mac app
  local browser on the Hub machine
```

Hub owns durable state, parent PIN, Cloud AI keys, paired-device registry,
runtime mode, guardrails, local/cloud reasoning, STT fallback, LuxTTS voice
profiles, and conversation history.

Clients own UI, mic/file-picker permissions, on-device STT when available,
temporary playback, stable client identity, and Hub pairing/session state.

## 2. Top-level repo map

```text
ToyTalk/
  README.md
  Makefile
  Cargo.toml
  apps/
  crates/
  native/
  tools/
  packaging/
  models/
  schemas/
  docs/
  qa/
  third_party/
```

Generated/private files should stay outside the repo:

```text
~/Downloads/ToyTalk/artifacts
~/Downloads/ToyTalk/build
~/Downloads/ToyTalk/deps
~/Downloads/ToyTalk/test-results
~/Downloads/ToyTalk/private
```

## 3. Shared Flutter client: Android, iPhone, browser

Main directory:

```text
apps/android/flutter_app/
```

Important areas:

| Path | Purpose |
|---|---|
| `lib/src/app.dart` | Shared Flutter UI, settings, kids, characters, child mode, theme, Hub status |
| `lib/src/domain/app_state.dart` | App state machine and reducer |
| `lib/src/backend/backend_client.dart` | Client/backend abstraction |
| `lib/src/backend/backend_client_stub.dart` | Native Android/iOS Hub HTTP client via platform bridge |
| `lib/src/backend/backend_client_web.dart` | Browser wrapper for Hub-served local web client |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Android platform bridge: pairing storage, on-device STT, bounded fallback audio, playback, file pickers |
| `ios/Runner/PlushPalPlatformPlugin.swift` | iOS platform bridge: pairing storage, on-device STT target, bounded fallback audio, playback, file pickers |
| `web/plushpal_backend.js` | Local browser JavaScript bridge to the Hub |
| `test/` | Flutter unit/widget/backend tests |

Android and iPhone do not own kids, characters, Cloud AI keys, provider calls,
voice profiles, or conversation history. Those calls go through the Hub.

Common commands:

```sh
cd apps/android/flutter_app
flutter analyze
flutter test
flutter build apk --debug
```

## 4. ToyTalk Hub backend

Main directory:

```text
apps/station/macstation_host/
```

This is the Rust Axum backend. It still uses the historical `macstation_host`
path name.

Important areas:

| Area | Purpose |
|---|---|
| `src/lib.rs` | Routes, auth, storage routing, parent PIN, provider config, local model install, voice APIs, STT, conversation turns |
| `src/main.rs` | Runtime assembly, mode selection, model/voice/STT startup |
| `assets/flutter_web/` | Generated Flutter web bundle served by Hub |
| `examples/` | Local smoke examples |
| `src/bin/` | Helper binaries/scripts wired into Hub development flows |

Important API groups:

```text
/api/v1/bootstrap
/api/v1/health
/api/v1/status
/api/v1/parent-pin/*
/api/v1/provider/*
/api/v1/model/*
/api/v1/paired-clients/*
/api/v1/kids/*
/api/v1/characters/*
/api/v1/voice/*
/api/v1/stt/transcribe
/api/v1/conversation/turn
/api/v1/history/*
/api/v1/events
/api/v1/commands
```

Hub storage routing uses:

```http
X-PlushBuddy-Client-Id: <stable client id>
X-PlushBuddy-Hub-Id: <stable hub id>
```

Hub-owned APIs open the Hub-scoped encrypted store. Family-data APIs open the
client-scoped encrypted store for the requesting device.

## 5. macOS apps

```text
apps/macos/station_app/AppShell.swift
apps/macos/client_app/AppShell.swift
```

### ToyTalk Hub app

`apps/macos/station_app/AppShell.swift` is the Hub setup/supervisor app. It:

- prepares safe preflight work in parallel where possible: app-support storage,
  LAN discovery, device capability/model recommendation environment, and
  LuxTTS voice-runtime checks/downloads;
- starts and health-checks the Rust backend after required runtime paths are
  known;
- keeps phone/browser/Mac-client options hidden until the Hub is fully healthy;
- shows row-level setup progress so independent setup work can turn green
  separately without exposing partially usable client flows;
- prepares LuxTTS/STT/model runtime dependencies;
- configures parent PIN;
- configures Cloud AI provider keys in Hub SQLCipher;
- starts Local AI model install when selected;
- shows Hub health and paired devices;
- creates QR pairing links for Android/iPhone/external clients;
- opens the local browser client;
- opens the native Mac client.

Packaged app:

```text
~/Downloads/ToyTalk/artifacts/macos/ToyTalk Hub.app
```

### ToyTalk Mac client

`apps/macos/client_app/AppShell.swift` is a native WKWebView shell around the
same Hub-backed client UI. It does not start services or own durable data.

Packaged app:

```text
~/Downloads/ToyTalk/artifacts/macos/ToyTalk.app
```

## 6. Local browser client

The browser client is generated from the shared Flutter app and served by Hub:

```text
apps/android/flutter_app/web/
apps/station/macstation_host/assets/flutter_web/
```

Use:

```sh
make desktop
```

Do not hand-edit generated `main.dart.js`. Edit Flutter/Dart/JS source, rebuild,
then let packaging copy the generated bundle.

The browser is local-only on the same machine as Hub. Remote LAN browser clients
are intentionally out of scope.

## 7. Voice tooling

Main directory:

```text
tools/voice/
```

| Path | Purpose |
|---|---|
| `setup_luxtts_macos.sh` | LuxTTS runtime setup |
| `luxtts_worker.py` | Persistent LuxTTS worker used by Hub |
| `luxtts_tts.py` | One-shot LuxTTS health/smoke wrapper |
| `denoise_reference.py` | Reference cleanup experiment helper |
| `chatterbox_tts.py` | Chatterbox fallback/research wrapper |
| `openvoice_tts.py`, `gptsovits_tts.py` | Research/bakeoff wrappers |

Bakeoff outputs belong under `~/Downloads/ToyTalk/test-results` or
`~/Downloads/ToyTalk/private`, not the repo.

## 8. Shared Rust crates

| Crate | Purpose |
|---|---|
| `core_domain` | Shared domain/conversation types |
| `parent_controls` | Parent PIN/profile policy |
| `character_voice` | Voice enrollment validation/state |
| `encrypted_storage` | SQLCipher schema, migrations, encrypted records |
| `platform_key_vault` | Platform key wrapping support |
| `desktop_gateway` | Desktop gateway/auth helpers |
| `device_capability` | Mac capability detection and local model recommendation |
| `model_lifecycle` | Signed model manifest/install lifecycle |
| `local_llm_llamacpp` | llama.cpp local AI model adapter |
| `policy_engine` | Guardrails, redaction, prompt contract |
| `cloud_provider` | Gemini/OpenAI cloud provider boundary |
| `provider_api` | Provider interface types |
| `application` | Conversation orchestration |
| `mobile_bridge` | Mobile/native bridge types |

## 9. Native ABI directories

```text
native/llama_abi/
native/key_vault_abi/
```

These support local model/runtime and secure-storage boundaries. They are
lower-level than normal feature work.

## 10. Packaging

```text
packaging/
```

Common commands:

```sh
make public-artifacts
make package-macos
make android-apk
make ios-simulator
make ios-device
```

Public-style artifacts are written under `~/Downloads/ToyTalk/artifacts`.

## 11. QA

```text
qa/
```

Useful commands:

```sh
qa/automation/run_local_quality_gate.sh
qa/automation/android_device_smoke.sh
qa/automation/android_station_pairing_smoke.sh
qa/automation/ios_simulator_smoke.sh
qa/automation/macstation_api_smoke.py
qa/automation/macstation_live_reasoning_smoke.mjs
```

Some script names still say `station`; they target ToyTalk Hub.
