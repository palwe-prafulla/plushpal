# PlushPal Repository Execution Plan

Status: Active  
Baseline: Product Requirements and Architecture v5.0  
Delivery target: Supervised cross-platform private beta

## Working agreement

Every stage is implemented in dependency order. A stage is complete only when its code, unit tests, documentation, formatting, strict lint, and workspace tests pass. Safety-, privacy-, storage-, and network-sensitive behavior must have negative tests as well as happy-path tests. Integration or device tests supplement unit tests; they never replace them.

The implementation remains local-first. Local conversation is the baseline. Search and cloud modes are separately parent-controlled and fail closed when policy, consent, capability, or provider eligibility is missing.

## Stage 0 — Foundation and contracts

Deliverables:

- Rust workspace, reproducible toolchain, formatting/lint/test commands.
- Core conversation, age-policy, provider, search, and orchestration contracts.
- Versioned provider-response and search-evidence schemas.
- ADR template and shared-core boundary ADR.

Unit-test gate:

- Age-band authorization and Unicode bounds.
- Provider output is revalidated locally after generation.
- Workspace formatting, Clippy with warnings denied, and all tests pass.

Status: Complete at the reusable-core level. The lifecycle includes Ed25519-signed manifest verification and a production resumable HTTPS downloader with public-address validation on every redirect, response/size caps, streaming SHA-256 verification, durable partial files, and atomic finalization. The private-beta catalog contains a signed exact manifest for the official Qwen3 1.7B Q8_0 artifact. Desktop/mobile installer UX is integrated; live interrupted-download evidence remains a release-matrix task.

## Stage 1 — Device capability and model recommendation

Status: Complete.

Deliverables:

- Platform-neutral device profile and capability facts.
- Versioned model requirements for standard and enhanced local tiers.
- Deterministic eligibility evaluation with explicit rejection reasons.
- Highest-quality eligible recommendation without downloading a model.
- Native probe interfaces for later Swift, Kotlin, macOS, and Windows adapters.

Unit-test gate:

- Enhanced devices select the 4B tier; standard devices select the 1.7B tier.
- Low memory, low storage, old OS, unsupported architecture, and missing acceleration fail safely.
- Memory headroom and storage reserve boundaries are tested exactly.
- Candidate ordering cannot select an ineligible higher tier.

## Stage 2 — Model manifest and lifecycle

Status: Complete.

Deliverables:

- Signed-manifest domain model, hash/license/runtime compatibility validation.
- Resumable downloader interface with progress, cancellation, and size caps.
- Staging, self-test, atomic activation, last-known-good rollback, and removal.
- Separate stores for public model weights and encrypted user data.

Unit-test gate:

- Invalid hash/signature/size/license/runtime never activates.
- Interrupted download or activation preserves the active model.
- Rollback and disk-space accounting are deterministic.
- Cancellation removes or quarantines incomplete artifacts.

## Stage 3 — Local conversation provider

Status: In progress. The provider, bounded prompt/structured-output layer, normalized failures, fixture backend, versioned asynchronous C ABI, and lifecycle-safe native adapter cover create/load/generate/read/cancel/unload, deterministic options, deadlines, and metrics. Official llama.cpp release b9637 is pinned at commit `aedb2a5e9ca3d4064148bbb919e0ddc0c1b70ab3`; its Metal/Accelerate build and ABI conformance test pass on Apple Silicon. The native runtime now applies the model-owned Qwen chat template, disables visible reasoning, and permits only a closed reasoning prefix before strict JSON validation. The exact signed 1.7B Q8 artifact passes release-mode load, child-safe generation, and live cancellation on Apple Silicon. Cross-device benchmarks and fuzz jobs remain.

Deliverables:

- llama.cpp adapter crate behind `ConversationProvider`.
- Safe native ABI for load, generate, cancel, unload, and metrics.
- Prompt rendering, context cap, deterministic sampling defaults, structured output parser.
- Fixture provider and benchmark harness independent of model weights.

Unit-test gate:

- Prompt boundaries and structured-response parsing are fuzzable and bounded.
- Timeout/cancellation/model-load/memory failures normalize correctly.
- Malformed or oversized output is rejected before synthesis.
- Test adapter proves orchestration without native inference.

## Stage 4 — Encrypted persistence and retention

Status: Code complete for the Mac MVP. Transactional repository semantics, session-only and 1/7/30-day retention, PIN-gated review/deletion, minimized projection, migration, and fail-closed cipher/key-vault bootstrap are implemented. SQLCipher protects desktop settings, characters, sessions, turns, voice metadata, and caches. Reference voice WAVs use AES-256-GCM with a unique vault-held key and path for every enrollment; replacement commits the new asset before best-effort erasure of the superseded asset, and delete removes the key before metadata. Android protects the complete parent profile and history with Keystore AES-GCM; iOS stores both in the device-only Keychain. Windows/mobile voice persistence and device verification remain matrix work.

Deliverables:

- Repository interfaces, migration runner, encrypted database adapter boundary.
- Key-vault and wrapped-key interfaces for every platform.
- Character, voice asset, conversation, settings, audit, and model records.
- Session-only default, optional retention, expiry, delete-session, character deletion, delete-all.

Unit-test gate:

- Transaction rollback, migration, retention clock, and crypto-erasure behavior.
- Secrets and binary assets cannot serialize into external DTOs.
- Interrupted deletion resumes safely and idempotently.

## Stage 5 — Conversation state machine and safety pipeline

Status: Text-conversation and safety orchestration are implemented. The current client flow includes consented audio import, local/browser normalization from M4A/MP4 AAC, WAV, MP3, OGG, or WebM into mono 16-bit WAV, local room-tone gating, quality inspection, encrypted reference-audio persistence on MacStation, LuxTTS voice-clone synthesis, parent preview-required voice-match approval, approval-gated voice playback, and deletion. In-app recording UI, objective speaker-similarity scoring, and physical-device voice evidence remain open. Desktop/mobile clients reject forged age/character scope and keep parent/kid/character state in the active client.

Deliverables:

- Typed asynchronous job/state machine from capture through playback.
- Immutable prompt layers, input/output policy, trusted-adult escalation, deterministic fallbacks.
- Local authoritative context and separate minimized cloud projection.
- Cancellation, stale-result rejection, interruption, and recovery.

Unit-test gate:

- Exhaustive valid/invalid state transitions and randomized cancellation ordering.
- Age-policy corpus tests for each model/mode combination.
- Parent guidance cannot override immutable policy.
- Disabled history is destroyed at session end.

## Stage 6 — Curated search

Status: Complete for the private-beta adapter. Query minimization, strict Brave SafeSearch, vault-only credentials, production rustls HTTPS, DNS pinning, public-address validation on every redirect, content bounds, active-content removal, untrusted evidence, SQLCipher cache persistence, citation validation, and contradictory-evidence fallback are implemented.

Deliverables:

- Query sanitizer and PII minimizer.
- HTTPS fetch boundary, redirect validation, DNS/private-address blocking, size/type caps.
- Active-content removal, untrusted-evidence representation, source records, encrypted bounded cache.
- Grounding validator and safe uncertainty response.

Unit-test gate:

- Loopback, link-local, private, rebinding, redirect, oversized, and unsupported content cases fail closed.
- Retrieved prompt injection cannot change policy or tool permissions.
- Unsupported claims and contradictory evidence trigger safe fallback.

## Stage 7 — Experimental cloud provider

Status: Adapter code complete and intentionally fail-closed. Ed25519-signed eligibility registries, per-turn consent/age/channel/retention/expiry enforcement, minimized stateless DTOs, an OpenAI Responses API rustls transport with structured output and `store: false`, and platform vault paths are implemented. Enabling UI/live use remains excluded until parent credentials and provider qualification evidence exist.

Deliverables:

- Signed, expiring provider-eligibility registry.
- Parent-only credential references and platform vault integration.
- OpenAI-compatible stateless development/private-beta adapter.
- Explicit consent, minimized DTO, no remote conversation IDs, provider/model/region enforcement.

Unit-test gate:

- Missing/expired/incompatible eligibility blocks validation and generation.
- Keys never enter UI state, database records, logs, URLs, or diagnostics.
- Local mode remains functional after credential removal or network failure.

## Stage 8 — Desktop host and shared presentation client

Status: Refocusing from embedded-Mac-app-first to PlushBuddy Station. The ephemeral host, embedded Flutter web assets, bootstrap/session security, strict request validation, WebSocket correlation, encrypted profile/history/reference voice, parent voice enrollment, local LuxTTS preview-required approval/playback, persistent LuxTTS worker startup with in-process model reuse and prompt-cache reuse by reference hash, local attach/external pairing host/origin allowlisting, and reproducible macOS packaging are implemented. The macOS shell now acts as a native setup/health supervisor: it verifies user-scoped app storage, verifies or installs LuxTTS under `~/Library/Application Support/PlushPal`, starts the local host, shows service health, opens the browser client, launches the Mac client, and shows QR pairing only for external Android/iPhone clients. Browser and Mac clients launched from Station auto-attach by exchanging a one-time bootstrap token for a Station session cookie and removing the token from the URL; they do not require QR scanning. For Android/iPhone pairing, Station detects a LAN IPv4 address, starts the host with an exact LAN host allowlist, and displays a one-time LAN bootstrap QR code. External mobile clients scan that QR, store the Station session encrypted with Android Keystore or iOS Keychain, and route only voice-profile creation, preview, approval/deletion, and TTS synthesis to Station. Client-owned parent data, kids, characters, history, Gemini/OpenAI API keys, guardrail prompt construction, and conversation reasoning remain on the active client. Pocket TTS, Chatterbox, Qwen/llama.cpp, and other voice/reasoning experiments are retained as research or fallback evidence; the current product voice path is LuxTTS.

Deliverables:

- Signed Rust host serving embedded Flutter web assets on loopback only.
- Ephemeral port, bootstrap secret, authenticated session, strict Host/Origin/CORS/CSP/WebSocket checks.
- Versioned command/event API and initial parent/child Flutter flows.
- Native PlushBuddy Station shell with explicit health rows for storage, voice engine, local service, local browser/Mac attach readiness, and Android/iPhone pairing readiness.
- Local browser/Mac bootstrap attach plus LAN pairing bootstrap QR generation with exact Host/Origin allowlisting for the detected Mac LAN address.
- User-scoped runtime/cache locations that are reused across app launches and preserved when running services are stopped on app close.
- Desktop audio, lifecycle, installer, migration, rollback, restart, and uninstall behavior.

Unit-test gate:

- CSRF, DNS rebinding, malicious Origin/Host, token replay, oversized body, path traversal, and idle shutdown.
- UI state reducers cover every typed event and error.
- Browser client cannot obtain credentials or unrestricted paths.
- Station startup logic must not open the embedded WebView until required health checks pass and the user chooses that path.

## Stage 9 — iOS and Android hosts plus speech

Status: Android and iPhone bridge code is build-verified for the current MVP. Bounded PCM buffering, permission/interruption behavior, stale-callback rejection, Flutter MethodChannel contracts, Android SpeechRecognizer/TextToSpeech + WAV playback, iOS SFSpeechRecognizer/AVSpeechSynthesizer + WAV playback, Android Keystore and iOS Keychain encrypted parent profile/history/provider key/Station pairing, direct mobile Gemini/OpenAI reasoning, local kid/character/photo metadata, native audio-file picking for M4A/WAV/MP3/AAC/OGG/WebM upload to Station, and Station-only cloned voice routing are implemented. The Android debug APK, iPhone simulator app, and unsigned iPhone device app build successfully with the lightweight native bridge.

Deliverables:

- Generated Flutter/native bridge and stable Rust/C/C++ boundaries.
- Local STT and TTS adapters, bounded audio buffers, interruptions, routes, focus, cancellation.
- iOS Keychain/file protection/model delivery and Android Keystore/internal storage/model delivery.
- Capability probes, Android Gemini-key setup, and optional local-model selection connected to onboarding.

Unit-test gate:

- Native bridge ownership/error/cancellation tests.
- Audio conversion, buffer bounds, interruption, permission denial, and stale callback tests.
- Platform key/storage adapters tested with simulator/emulator fakes; physical-device integration gates remain mandatory.

## Stage 10 — System verification and release

Deliverables:

- Desktop/mobile end-to-end workflows, privacy network captures, safety corpus, accessibility reviews.
- Performance/thermal/memory matrix and unsupported-device UX.
- SBOM, license ledger, signed artifacts, installers, store declarations, support/incident/rollback runbooks.
- Requirements-to-test traceability and release evidence package.

Completion gate:

- No unresolved critical/high security or privacy findings.
- All mandatory requirements have passing evidence or an owned, expiring waiver.
- Local conversations work offline after installation; all external traffic matches field allowlists.
- Installation, upgrade, rollback, migration, retention, deletion, and uninstall pass on the supported matrix.

## Continuous verification

Every change runs:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p plushpal-desktop-host --example model_smoke --features native-runtime
cargo check -p plushpal-desktop-host --example voice_smoke --features native-runtime
git diff --check
```

Later stages add schema, fuzz, native, Flutter, privacy-network, safety-corpus, physical-device, and packaging jobs without weakening these baseline checks.

Latest verified development snapshot:

- Rust formatting and strict Clippy pass on Rust 1.86.0.
- All 114 authored Rust unit/integration tests pass, including bounded session context, signed model catalog, SQLCipher profile/history/voice-metadata/delete-all round trips and plaintext scans, signed registry/manifest tamper tests, parent lockout, character/WAV validation, native/mobile FFI lifecycle tests, and fourteen real-router desktop-host tests including the parent-gated voice lifecycle.
- All Flutter reducer/widget/platform/backend tests plus browser-audio normalization tests cover model readiness/installation, parent PIN setup/exit authorization, character/privacy editing, retained-history review, persisted-profile restoration, voice enrollment, preview-required approval, spoken-turn playback, local audio import normalization, deletion, and session cleanup. Dart static analysis and release web compilation are part of the local gate.
- Flutter release web compilation succeeds and the result is embedded into the desktop binary without runtime filesystem access.
- Pinned llama.cpp compiles from source and its native ABI conformance test passes.
- The Apple Security.framework key-vault ABI compiles and passes store/read/delete conformance against Keychain.
- The exact signed Qwen3 1.7B Q8_0 artifact passes release-mode structured generation and active cancellation on Apple M4 Pro; the packaged ad-hoc-signed macOS application starts with that verified model.
- Full MacStation E2E has passed for LuxTTS health, Sheru/Jenna/Buddy M4A-derived voice enrollment, preview/approval, unique profile IDs, and approved WAV synthesis. Live Gemini command/WebSocket reasoning has passed as a smoke test. The product voice path is now LuxTTS; Pocket TTS, Chatterbox, Qwen voice, and other bakeoff outputs are retained only as experiment/pipeline evidence.
- `make verify-release-local` executes the consolidated local release gate, compiles the feature-gated conversation and voice smoke targets, and produces a byte-reproducible macOS package through normalized archive timestamps.
- Swift plugin syntax parsing passes. `flutter analyze`, `flutter test`, `make ios-simulator`, and unsigned iPhone device build verification pass locally with full Xcode 26.5, CocoaPods 1.16.2, and the iOS 26.5 simulator runtime installed.
