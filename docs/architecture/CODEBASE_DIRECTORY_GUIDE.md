# PlushBuddy Codebase Directory Guide

Last updated: 2026-06-25

This guide explains where the current Android, browser, Mac client, and MacStation MVP code lives and how the directories relate to each product surface.

## 1. Mental model

The repo is a monorepo with six important product/code areas:

```text
PlushPal/
  apps/android/flutter_app/        Android app + iPhone app + browser client + shared Flutter UI source
  apps/macos/client_app/           PlushBuddy native Mac client shell
  apps/macos/station_app/          PlushBuddy Station native setup shell
  apps/station/macstation_host/    MacStation / local web host in Rust
  apps/web/                        Web/Mac-browser surface notes and build ownership
  tools/voice/                     Python voice-model setup and generation scripts
  crates/                          Shared Rust domain/storage/model crates
```

The most important split:

- Android app = `apps/android/flutter_app` plus Android native code under `apps/android/flutter_app/android`.
- iPhone app = `apps/android/flutter_app` plus iOS native code under `apps/android/flutter_app/ios`.
- Browser client = the same Flutter UI plus `apps/android/flutter_app/web/plushpal_backend.js` and `backend_client_web.dart`.
- Mac client app = `apps/macos/client_app`, a native WKWebView shell that opens the Station-served client UI.
- MacStation setup app = `apps/macos/station_app`, a native setup/health shell that launches services and can open the Mac client.
- MacStation host = `apps/station/macstation_host` plus voice scripts under `tools/voice`.
- Browser UI = Flutter web build from `apps/android/flutter_app`, embedded into `apps/station/macstation_host/assets/flutter_web`, served by MacStation.
- Web build ownership notes = `apps/web`.
- Shared Rust libraries = `crates`.

## 2. Top-level repo map

```text
/Users/prafullakumarpalwe/projects/PlushPal
├── README.md
├── Makefile
├── Cargo.toml
├── apps/
├── crates/
├── tools/
├── third_party/
├── native/
├── packaging/
├── docs/
├── models/
├── schemas/
├── .github/
├── LICENSE
├── CONTRIBUTING.md
├── SECURITY.md
└── THIRD_PARTY.md
```

| Path | What it is | Usually edit? |
|---|---|---:|
| `README.md` | project overview and quick commands | yes |
| `Makefile` | common dev/build commands | yes |
| `Cargo.toml` | Rust workspace config | sometimes |
| `apps/` | runnable apps | yes |
| `crates/` | reusable Rust libraries | yes |
| `tools/` | developer/model scripts | yes |
| `third_party/` | small pinned source dependencies, not downloaded models | rarely |
| `native/` | C/C++ ABI bridges | rarely |
| `packaging/` | macOS/Android/Windows packaging scripts | sometimes |
| `docs/` | specifications and architecture docs | yes |
| `models/` | model manifests/runtime cache area | rarely |
| `schemas/` | JSON schemas | sometimes |
| `.github/` | CI and PR-governance workflows | sometimes |
| `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `THIRD_PARTY.md` | public-repo policy and notices | rarely |

Generated/private local directories are intentionally not part of the source
tree:

```text
~/Downloads/PlushPal/artifacts      packaged app outputs
~/Downloads/PlushPal/build          external build workspace
~/Downloads/PlushPal/deps           downloaded LuxTTS/runtime dependencies
~/Downloads/PlushPal/test-results   QA evidence
~/Downloads/PlushPal/private        local private samples/scratch data
```

Ignored legacy/dev paths such as `audio-samples/`, `test-artifacts/`, `target/`,
`build/`, `dist/`, `.venv-*`, and model caches should not be committed.

## 3. Mobile apps: Android and iPhone

Main directory:

```text
apps/android/flutter_app/
```

### 3.1 Mobile app structure

```text
apps/android/flutter_app/
├── lib/
│   └── src/
│       ├── app.dart
│       ├── backend/
│       ├── domain/
│       └── platform/
├── android/
│   └── app/
│       ├── src/main/kotlin/com/plushpal/plushpal_ui/MainActivity.kt
│       ├── src/main/cpp/
│       └── build.gradle.kts
├── assets/
├── test/
├── web/
├── ios/
├── pubspec.yaml
└── README.md
```

### 3.2 What each Android area does

| Path | Purpose |
|---|---|
| `apps/android/flutter_app/lib/src/app.dart` | Main UI, app state, onboarding, settings, child mode, kid/character flows |
| `apps/android/flutter_app/lib/src/backend/backend_client.dart` | Abstract app/backend interface |
| `apps/android/flutter_app/lib/src/backend/backend_client_stub.dart` | Android MethodChannel client and MacStation HTTP client |
| `apps/android/flutter_app/lib/src/backend/backend_client_web.dart` | Browser backend wrapper for JS-local storage, cloud reasoning, and Station voice |
| `apps/android/flutter_app/lib/src/domain/app_state.dart` | App state machine and reducer |
| `apps/android/flutter_app/lib/src/platform/platform_bridge.dart` | Device/platform contract for speech, secrets, profile |
| `apps/android/flutter_app/android/app/src/main/kotlin/.../MainActivity.kt` | Android native implementation |
| `apps/android/flutter_app/ios/Runner/PlushPalPlatformPlugin.swift` | iOS native implementation |
| `apps/android/flutter_app/android/app/src/main/cpp/` | Native bridge glue for Rust/mobile library |
| `apps/android/flutter_app/test/` | Flutter unit/widget tests |
| `apps/android/flutter_app/assets/fonts/` | Bundled fonts |
| `apps/android/flutter_app/web/` | Flutter web shell, browser backend JS, audio normalization JS |

### 3.3 If you want to change Android UI

Start here:

```text
apps/android/flutter_app/lib/src/app.dart
```

Examples:

| Change | File |
|---|---|
| Home screen layout | `apps/android/flutter_app/lib/src/app.dart` |
| Settings screens | `apps/android/flutter_app/lib/src/app.dart` |
| Kid/character forms | `apps/android/flutter_app/lib/src/app.dart` |
| Child chat/mic UI | `apps/android/flutter_app/lib/src/app.dart` |
| Copy/text labels | `apps/android/flutter_app/lib/src/app.dart` |
| State transition rules | `apps/android/flutter_app/lib/src/domain/app_state.dart` |

### 3.4 If you want to change Android native behavior

Start here:

```text
apps/android/flutter_app/android/app/src/main/kotlin/com/plushpal/plushpal_ui/MainActivity.kt
```

Examples:

| Change | Area in `MainActivity.kt` |
|---|---|
| Store Gemini/OpenAI key | `saveProviderApiKey`, encrypted value helpers |
| Change cloud prompt | `buildReasoningPrompt` |
| Change Gemini call | `generateWithGemini` |
| Change OpenAI call | `generateWithOpenAI` |
| Change mic behavior | `listen`, `ensureMicrophonePermission` |
| Change speech-recognition error messages | `speechRecognizerMessage` |
| Change local encrypted storage | `writeEncryptedValue`, `readEncryptedValue` |
| Change Android kid/character persistence | `kids`, `saveKid`, `characters`, `saveCharacter` |
| Change station pairing storage | `saveStationPairing`, `stationPairingStatus` |
| Change file picker behavior | `pickVoiceSample`, `pickCharacterPhoto` |

### 3.5 Android tests

```text
apps/android/flutter_app/test/
```

Common command:

```sh
cd apps/android/flutter_app
flutter analyze
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### 3.6 iPhone build/test commands

The iPhone app uses the same Flutter UI and backend contract, with native iOS implementations for Keychain storage, speech recognition, audio playback, QR/local-network permissions, file picking, cloud reasoning, and MacStation pairing.

```sh
make ios-simulator
make ios-device
```

These require full Xcode selected with `xcode-select`; Command Line Tools alone are not enough. The iOS Rust bridge also requires:

```sh
rustup target add aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-ios
```

## 4. MacStation

Main directory:

```text
apps/station/macstation_host/
```

### 4.1 MacStation structure

```text
apps/station/macstation_host/
├── src/
│   └── lib.rs
├── examples/
├── assets/
│   └── flutter_web/
├── Cargo.toml
└── build.rs
```

### 4.2 What MacStation does

MacStation is the local voice appliance and local web host. It:

- starts/verifies local services;
- exposes the local HTTP API;
- handles automatic local bootstrap attach for browser/Mac clients;
- handles QR bootstrap/pairing for Android/iPhone clients;
- owns the LuxTTS voice profile lifecycle;
- stores encrypted voice references;
- generates preview/conversation WAV files;
- can serve the browser/Mac web UI.

### 4.3 Important MacStation code

| File/area | Purpose |
|---|---|
| `apps/station/macstation_host/src/lib.rs` | Most MacStation runtime code |
| Axum route setup in `src/lib.rs` | `/api/v1/*` API map |
| `voice_status`, `enroll_voice`, `preview_voice`, `approve_voice`, `speak_with_voice` | voice profile and TTS APIs |
| `PersistentLuxTtsEngine` / LuxTTS engine area | starts and talks to Python worker |
| encrypted profile store area | SQLCipher + voice reference storage |
| bootstrap/session handlers | local browser/Mac attach, Android/iPhone QR pairing, and session auth |
| tests in `src/lib.rs` | Rust host API tests |

### 4.4 MacStation API endpoints

Implemented in:

```text
apps/station/macstation_host/src/lib.rs
```

Important endpoints:

```text
GET  /api/v1/health
POST /api/v1/bootstrap
GET  /api/v1/status
GET  /api/v1/voice/status
POST /api/v1/voice/enroll
POST /api/v1/voice/preview
POST /api/v1/voice/approve
POST /api/v1/voice/delete
POST /api/v1/voice/speak
GET  /api/v1/characters
POST /api/v1/characters/save
POST /api/v1/characters/delete
POST /api/v1/history/list
POST /api/v1/history/delete
GET  /api/v1/events
POST /api/v1/commands
```

For Android MVP, the most important endpoints are:

```text
/api/v1/bootstrap
/api/v1/health
/api/v1/status
/api/v1/voice/status
/api/v1/voice/enroll
/api/v1/voice/preview
/api/v1/voice/approve
/api/v1/voice/speak
```

### 4.5 MacStation commands

```sh
make setup-luxtts-voice
make run-mac-luxtts
make package-macos
open "$HOME/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app"
```

## 5. macOS apps

There are two native macOS app shells:

```text
apps/macos/
├── station_app/
│   └── AppShell.swift
└── client_app/
    └── AppShell.swift
```

### 5.1 PlushBuddy Station app

`apps/macos/station_app/AppShell.swift` is the setup/supervisor app. It:

- verifies local storage;
- installs/reuses LuxTTS runtime assets;
- starts `plushpal-desktop-host`;
- shows setup/health status;
- shows Android/iPhone pairing QR;
- opens the browser client;
- launches the separate `PlushBuddy.app` Mac client.

It is packaged as:

```text
~/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app
```

### 5.2 PlushBuddy Mac client app

`apps/macos/client_app/AppShell.swift` is the user-facing Mac app shell. It:

- loads the Station-served Flutter web client in a dedicated `WKWebView`;
- uses the same client UX as the browser path;
- supports normal macOS file pickers for photos and voice samples;
- does not install models or start local services.

It is packaged as:

```text
~/Downloads/PlushPal/artifacts/macos/PlushBuddy.app
```

The Station package also embeds a copy at:

```text
~/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app/Contents/Resources/PlushBuddy.app
```

That embedded copy is what Station launches from the **Open PlushBuddy Mac app** button.

## 6. Browser web app

The browser app uses the same Flutter source as Android:

```text
apps/android/flutter_app/lib/
apps/android/flutter_app/web/
```

When built for desktop hosting:

```sh
make desktop
```

Flutter web output is copied into:

```text
apps/station/macstation_host/assets/flutter_web/
```

That embedded web bundle is then served by the Rust desktop host.

Runtime ownership:

- browser stores parent/kid/character/history/provider selection locally;
- browser keeps provider API keys session-only rather than persisting them to
  localStorage;
- browser calls Gemini/OpenAI directly for reasoning;
- browser calls MacStation only for bootstrap/status and `/api/v1/voice/*`;
- MacStation CSP allows only same-origin plus Gemini/OpenAI provider connections.

### What to edit for browser UI

| Change | File |
|---|---|
| UI screens | `apps/android/flutter_app/lib/src/app.dart` |
| Web backend JS bridge | `apps/android/flutter_app/web/plushpal_backend.js` |
| Dart web backend wrapper | `apps/android/flutter_app/lib/src/backend/backend_client_web.dart` |
| Browser backend tests | `apps/android/flutter_app/test/plushpal_backend_web_test.mjs` |
| Embedded generated web bundle | `apps/station/macstation_host/assets/flutter_web/` after build |

Important: edit Flutter source and web source, then rebuild. Do not hand-edit generated `main.dart.js` unless debugging.

## 7. Voice tooling and model experiments

Main directory:

```text
tools/voice/
```

### 6.1 Voice scripts

| Path | Purpose |
|---|---|
| `tools/voice/setup_luxtts_macos.sh` | Creates LuxTTS virtualenv and installs requirements |
| `tools/voice/luxtts_worker.py` | Persistent worker used by MacStation |
| `tools/voice/luxtts_tts.py` | One-shot LuxTTS wrapper / healthcheck |
| `tools/voice/denoise_reference.py` | Denoise experiment helper |
| `tools/voice/chatterbox_tts.py` | Chatterbox experiment wrapper |
| `tools/voice/openvoice_tts.py` | OpenVoice experiment wrapper |
| `tools/voice/gptsovits_tts.py` | GPT-SoVITS experiment wrapper |
| `tools/voice/setup_chatterbox_macos.sh` | Chatterbox setup |

### 6.2 Bakeoff scripts

```text
tools/voice_bakeoff.py
tools/voice_stability_bakeoff.py
tools/voice_next_model_bakeoff.py
tools/voice_luxtts_denoise_bakeoff.py
tools/voice_chatterbox_tuning.py
```

Outputs should stay outside commits, preferably under:

```text
~/Downloads/PlushPal/test-results/
```

### 6.3 Voice virtualenvs

These are generated local runtime folders:

```text
.venv-luxtts/
.venv-chatterbox/
.venv-openvoice/
.venv-gptsovits/
.venv-f5tts/
.venv-mlx-audio/
```

Usually do not edit these. Recreate them through setup scripts if needed.

## 8. Shared Rust crates

Main directory:

```text
crates/
```

These are reusable Rust components from the larger local-first architecture. Some are active in the current MVP; some are legacy/future-facing from the earlier fully-local design.

| Crate | Purpose |
|---|---|
| `core_domain` | Shared conversation/domain types |
| `parent_controls` | Parent profile validation and PIN policy |
| `character_voice` | Voice enrollment validation/state concepts |
| `encrypted_storage` | SQLCipher database, migrations, encrypted records |
| `platform_key_vault` | Native platform vault integration |
| `desktop_gateway` | Desktop gateway/auth boundaries |
| `application` | Higher-level app orchestration |
| `cloud_provider` | Cloud provider abstractions/experiments |
| `local_llm_llamacpp` | llama.cpp local LLM adapter |
| `llama_native_ffi` | Rust FFI to native llama runtime |
| `mobile_bridge` | Mobile command bridge types |
| `model_lifecycle` | signed model install/download lifecycle |
| `device_capability` | device profile/capability checks |
| `audio_core` | audio validation/processing concepts |
| `policy_engine` | safety/policy rules |
| `provider_api` | provider response boundaries |
| `curated_search` | earlier curated search support |
| `search_api` | search API contracts |
| `session_engine` | session state concepts |

For the current Android + MacStation MVP, the most practically relevant crates are:

```text
core_domain
parent_controls
character_voice
encrypted_storage
platform_key_vault
desktop_gateway
```

## 9. Native ABI directories

Main directory:

```text
native/
```

```text
native/
├── key_vault_abi/
├── llama_abi/
├── mobile_bridge/
└── speech_abi/
```

These are C/C++ ABI boundaries for native integration. They are mostly from the earlier local-model architecture and lower-level runtime integrations.

Usually edit only if changing Rust/native FFI behavior.

## 10. Packaging

Main directory:

```text
packaging/
```

```text
packaging/
├── android/
│   └── build-rust.sh
├── macos/
│   └── package.sh
└── windows/
```

Common commands:

```sh
make public-artifacts
make android-rust
make package-macos
make verify-release-local
```

Generated packaged outputs:

```text
~/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app
~/Downloads/PlushPal/artifacts/macos/PlushBuddy.app
~/Downloads/PlushPal/artifacts/macos/PlushBuddy-0.1.0-macos.zip
~/Downloads/PlushPal/artifacts/macos/PlushBuddy-0.1.0-macos.dmg
~/Downloads/PlushPal/artifacts/android/PlushBuddy-debug.apk
~/Downloads/PlushPal/artifacts/ios/PlushBuddy-iPhoneSimulator.app
~/Downloads/PlushPal/artifacts/ios/PlushBuddy-iPhoneOS-unsigned.app
```

## 11. Documentation

Main directory:

```text
docs/
```

```text
docs/
├── architecture/
│   ├── ANDROID_MACSTATION_MVP_ARCHITECTURE.md
│   └── CODEBASE_DIRECTORY_GUIDE.md
├── specifications/
├── implementation/
├── release/
└── adr/
```

| Path | Purpose |
|---|---|
| `docs/architecture/ANDROID_MACSTATION_MVP_ARCHITECTURE.md` | current MVP architecture |
| `docs/architecture/CODEBASE_DIRECTORY_GUIDE.md` | this directory guide |
| `docs/specifications/` | earlier product/design specs |
| `docs/implementation/` | execution plan |
| `docs/release/` | release verification/checklists |
| `docs/adr/` | architecture decision records |

## 12. Test artifacts and samples

Generated QA evidence and private samples are kept outside the source checkout.

### 12.1 Current QA output

```text
~/Downloads/PlushPal/test-results/
```

This is where product smoke tests, screenshots, UI dumps, and JSON reports are
written by default.

### 12.2 Private samples and historical bakeoffs

```text
~/Downloads/PlushPal/private/audio-samples/
```

This is where local source recordings should live. Treat as private data.

Historical local bakeoff folders may exist on a developer machine, but they
should remain ignored and outside commits. If preserved, keep them in an
external scratch/test-results area rather than the public checkout:

```text
~/Downloads/PlushPal/test-results/voice-full-reference-bakeoff-2026-06-20/
~/Downloads/PlushPal/test-results/voice-denoise-bakeoff-2026-06-20/
~/Downloads/PlushPal/test-results/next-model-bakeoff-2026-06-20/
~/Downloads/PlushPal/test-results/qwen17-bakeoff-2026-06-20/
~/Downloads/PlushPal/test-results/chatterbox-tuning-2026-06-20/
```

These are useful for understanding why LuxTTS was chosen and comparing generated previews.

## 13. Generated folders: usually do not edit

These directories are generated or local-machine runtime state:

```text
build/
target/
dist/
.venv-*/
apps/android/flutter_app/build/
apps/android/flutter_app/.dart_tool/
```

If something gets weird, these can often be deleted/rebuilt, but do not treat them as source code.

## 14. “Where do I make this change?” cheat sheet

| Task | Start here |
|---|---|
| Change Android home/settings/child UI | `apps/android/flutter_app/lib/src/app.dart` |
| Change Android navigation/state rules | `apps/android/flutter_app/lib/src/domain/app_state.dart` |
| Change Android encrypted storage | `apps/android/flutter_app/android/app/src/main/kotlin/.../MainActivity.kt` |
| Change Gemini/OpenAI prompt | `MainActivity.kt` → `buildReasoningPrompt` |
| Change Gemini/OpenAI API call | `MainActivity.kt` → `generateWithGemini` / `generateWithOpenAI` |
| Change mic/STT behavior | `MainActivity.kt` → `listen` |
| Change voice upload from Android | `backend_client_stub.dart` + `MainActivity.kt` picker |
| Change Station HTTP voice API | `apps/station/macstation_host/src/lib.rs` |
| Change LuxTTS settings | `Makefile`, `apps/station/macstation_host/src/lib.rs`, `tools/voice/luxtts_worker.py` |
| Change LuxTTS worker behavior | `tools/voice/luxtts_worker.py` |
| Change Station setup UI | `apps/macos/station_app/AppShell.swift` |
| Change Mac client shell | `apps/macos/client_app/AppShell.swift` |
| Change Mac app packaging | `packaging/macos/package.sh` |
| Change Android native/Rust packaging | `packaging/android/build-rust.sh` |
| Add Flutter tests | `apps/android/flutter_app/test/` |
| Add Rust host tests | `apps/station/macstation_host/src/lib.rs` test module |
| Document architecture decisions | `docs/adr/` |

## 15. Current product-surface split

### Android app

Source:

```text
apps/android/flutter_app/lib/
apps/android/flutter_app/android/
```

Owns:

- parent setup;
- kid profiles;
- character profiles;
- reasoning provider API keys;
- child conversation UX;
- STT;
- conversation history;
- pairing config;
- audio playback.

### MacStation

Source:

```text
apps/macos/station_app/
apps/station/macstation_host/
tools/voice/
packaging/macos/
```

Owns:

- setup health;
- local browser/Mac attach and Android/iPhone QR pairing;
- LuxTTS runtime;
- voice sample processing;
- encrypted voice profile storage;
- voice preview;
- voice synthesis.

### Mac client app

Source:

```text
apps/macos/client_app/
apps/android/flutter_app/lib/
apps/android/flutter_app/web/
```

Owns:

- native macOS window/shell;
- Station URL loading;
- macOS file-picker bridging;
- same parent/child UX as browser.

### Browser app

Source:

```text
apps/android/flutter_app/lib/
apps/android/flutter_app/web/
apps/station/macstation_host/assets/flutter_web/
```

Owns:

- local browser UI path;
- legacy/local web host integration;
- useful for Mac-only testing.

### Shared / future reusable core

Source:

```text
crates/
native/
schemas/
```

Owns:

- domain models;
- validation;
- encrypted storage;
- native bridges;
- model lifecycle experiments;
- local LLM legacy/future paths.
