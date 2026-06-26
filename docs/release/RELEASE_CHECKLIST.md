# PlushBuddy Private-Beta Release Checklist

Every checkbox requires attached evidence for the exact commit and artifact hash. A waiver must name an owner, expiry, affected platforms, and rollback trigger.

For a distribution-signed macOS build, set both `PLUSHPAL_CODESIGN_IDENTITY` and the matching Apple `PLUSHPAL_TEAM_ID`; packaging fails closed if either half of that signing identity is missing. Local verification uses an ad-hoc signature only.

## Public GitHub publication readiness

- [x] Repository has a top-level README with architecture, setup, build, run, and QA instructions.
- [x] Repository has a top-level MIT license.
- [x] Repository has contribution and security guidance.
- [x] Third-party/model/provider usage is documented.
- [x] Local secrets and private audio samples are outside the repository.
- [x] `.gitignore` excludes common secrets, private samples, generated voice/model artifacts, venvs, build outputs, and QA results.
- [x] `make public-artifacts` builds from an external workspace and writes artifacts under `~/Downloads/PlushPal/artifacts`.
- [x] Local QA writes evidence under `~/Downloads/PlushPal/test-results`.
- [x] June 25, 2026 QA pass covers public artifact build, unit/local quality gate, MacStation, LuxTTS voice E2E, packaged MacStation, browser, Mac client, Android real device, Android pairing, and iPhone simulator launch.
- [ ] Live Gemini/OpenAI UI conversation should be rerun before tagging a hosted release artifact, using a fresh local provider key that is not committed.

## Build and provenance

- [ ] Clean clone initializes the pinned llama.cpp submodule at the recorded commit.
- [ ] Rust, native CMake, Flutter, schema, and platform tests pass in CI.
- [ ] macOS/Windows/iOS/Android artifacts are reproducible from the release tag.
- [ ] SBOM and third-party license ledger match the shipped binaries and model.
- [ ] Artifacts and update manifests are signed; notarization/store validation passes.

## Privacy and security

- [ ] Client-owned Gemini/OpenAI reasoning succeeds with parent-provided API key; legacy/local model paths are clearly marked non-default if shipped.
- [ ] Network capture contains only approved cloud-provider traffic plus local MacStation traffic; voice samples never leave the LAN/client trust boundary.
- [ ] API keys never appear in logs, URLs, databases, crash reports, UI state snapshots, or WebSocket events.
- [ ] SQLCipher wrong-key, deletion, retention, and uninstall tests pass.
- [ ] Loopback Host/Origin/authentication, redirect/DNS rebinding, malformed model, and prompt-injection suites pass.

## Child safety and product

- [ ] Safety corpus passes for every age band and enabled provider mode.
- [ ] Trusted-adult escalation and deterministic offline/provider-failure fallbacks are spoken and visible.
- [ ] Parent authorization gates parent settings; child-mode exit returns to home without exposing settings.
- [ ] Voice enrollment proves adult authorization, local-only encrypted storage, preview-before-approval, approval-gated playback, replacement, and cryptographic deletion.
- [ ] The shipped voice model/runtime has documented commercial redistribution rights and matching SBOM/notices.
- [ ] Screen reader, keyboard, contrast, large-text, microphone denial, interruption, and offline UX reviews pass.

## Platform qualification

- [ ] macOS arm64 and supported Intel/Windows hardware complete install, upgrade, rollback, and uninstall.
- [ ] Supported iPhone/iPad and Android devices complete QR pairing, microphone/file-picker, playback, interruption, and background/foreground tests.
- [ ] Browser and Mac client launch from Station, auto-attach without QR scanning, and complete typed settings/character/voice/conversation flows.
