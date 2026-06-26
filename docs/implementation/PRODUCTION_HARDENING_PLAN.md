# Production hardening completion plan

Last updated: 2026-06-26  
Scope: finish the 10 public-production-readiness items identified after the
initial GitHub publication.

This plan is intentionally practical. The goal is not to make PlushBuddy a
hosted commercial product overnight; the goal is to make the public repo stable,
tryable, well-instrumented, and honest enough that a stranger can clone it,
understand it, run checks, and exercise core flows without hand-holding.

## Current status summary

| # | Original hardening item | Current status | Remaining work |
|---:|---|---|---|
| 1 | Make setup boringly reliable | Partial | Harden LuxTTS install/runtime verification and Station setup recovery |
| 2 | Add a demo mode | Partial | Demo voice exists; full app demo data/reasoning mode still needed |
| 3 | Improve README onboarding | Done | Keep screenshots/docs current |
| 4 | Add CI public clone validation | Done | Add more smoke coverage as new demo mode matures |
| 5 | Separate mock vs real integrations cleanly | Partial | Formal mode matrix: mock/demo/local_voice/cloud/full |
| 6 | Harden security/privacy | Partial | Browser local encryption, safety corpus, network/privacy regression tests |
| 7 | Better release artifacts | Partial | GitHub release script, checksums, release notes, optional signing path |
| 8 | MacStation reliability dashboard | Not done | Add diagnostics/log viewer/reset/retry UI |
| 9 | Add more E2E scripted tests | Partial | Add UI journey automation across Android/iOS/browser/Mac where practical |
| 10 | Document limitations clearly | Done | Keep updated as architecture evolves |

## Recommended completion order

1. MacStation reliability dashboard.
2. LuxTTS installer/setup hardening.
3. Full demo/mock mode and mode matrix.
4. More E2E scripted tests.
5. Release artifacts/checksums/GitHub release flow.
6. Deeper privacy/safety hardening.

Reasoning:

- Station reliability and LuxTTS setup are the highest user-facing failure
  risks.
- Full demo mode makes the public repo easy to try without paid keys or heavy
  model setup.
- E2E automation should follow the mode matrix so tests can run quickly and
  deterministically.
- Release packaging and deeper privacy hardening become more valuable after the
  core flows are easier to validate.

## Item 1 — Make setup boringly reliable

### Already done

- `make doctor` validates local toolchain and repo prerequisites.
- Public artifacts build outside the repo under `~/Downloads/PlushPal`.
- Public repo hygiene checks prevent common secrets/private artifacts.

### Remaining deliverables

- Station setup state machine with explicit phases:
  - app storage;
  - bundled runtime check;
  - LuxTTS source/runtime check;
  - Python environment check;
  - model cache check;
  - Rust host check;
  - LuxTTS worker readiness;
  - browser/Mac attach readiness;
  - mobile pairing readiness.
- Resumable/retryable setup operations.
- Detect and repair partial setup:
  - missing Python runtime;
  - missing LuxTTS checkout;
  - broken venv;
  - missing model cache;
  - failed worker healthcheck;
  - stale host process/port conflict.
- Version/checksum marker files for downloaded/runtime components where
  practical.
- Clear actionable error messages with copyable diagnostics.

### Acceptance criteria

- A fresh machine can run `make doctor` and receive clear next steps.
- Station never silently bounces back to the landing page after setup failure.
- Failed setup leaves a visible failed phase and a retry/reset option.
- Reopening Station after partial setup either resumes or reports the exact
  broken component.

### Tests

- Unit tests for setup phase reducer/state transitions.
- Scripted tests with intentionally missing LuxTTS/Python/model paths.
- Packaged Station launch smoke with:
  - clean app data;
  - already-installed runtime;
  - corrupted runtime marker;
  - forced worker failure.

## Item 2 — Add a demo mode

### Already done

- `PLUSHPAL_VOICE_ENGINE=demo` and `make run-mac-demo` provide synthetic voice
  synthesis.
- MacStation API smoke supports `--voice-engine demo --synthesize`.

### Remaining deliverables

- Full demo app mode:
  - demo kid;
  - demo toy buddy;
  - demo voice profile;
  - mock reasoning response;
  - mock or synthetic WAV playback;
  - no Gemini/OpenAI key required;
  - no LuxTTS download required.
- One-command demo:

```sh
make run-demo
```

- README path: “Try in 3 minutes.”
- UI banner clearly saying “Demo mode — synthetic voice, no cloud calls.”

### Acceptance criteria

- A fresh clone can run demo mode without private samples, API keys, Android
  phone, or LuxTTS.
- Demo mode exercises parent home, kid/character view, child chat, and audio
  playback.
- Demo mode cannot be confused with production voice quality.

### Tests

- MacStation demo API smoke.
- Browser demo smoke.
- Flutter tests for demo-state entry/exit.
- Optional Android/iOS simulator smoke using demo state.

## Item 3 — Improve README onboarding

### Status

Done.

### Already done

- Product-focused README intro.
- Screenshot gallery for Android, iPhone simulator, browser, and Mac client.
- Quick start with `make doctor` and `make public-artifacts`.
- Architecture-at-a-glance diagram.
- Documentation map.

### Ongoing maintenance

- Keep screenshots aligned with current UI.
- Keep “known limitations” current.
- Add demo-mode quick-start once full demo mode is complete.

## Item 4 — Add CI that validates public clone health

### Status

Done for baseline clone health.

### Already done

- `make public-repo-check`.
- CI public-repo job.
- README image checks.
- Required docs/assets checks.
- Secret pattern scan.
- Generated/private path tracking guard.

### Future improvements

- Add demo-mode smoke to CI after full demo mode lands.
- Add Markdown link checker.
- Add dependency/license inventory check.
- Add artifact-size guardrails.

## Item 5 — Separate mock vs real integrations cleanly

### Already done

- Demo voice mode exists.
- Real LuxTTS path remains separate.

### Remaining deliverables

- Define explicit runtime modes:

| Mode | Reasoning | Voice | Intended use |
|---|---|---|---|
| `mock` | fixture response | synthetic WAV | CI and fast local demo |
| `demo` | fixture/demo response | synthetic WAV | public try-it mode |
| `local_voice` | cloud or typed fixture | LuxTTS | voice quality testing |
| `cloud` | Gemini/OpenAI | synthetic/no voice | reasoning testing |
| `full` | Gemini/OpenAI | LuxTTS | real product flow |

- Central mode parser/config object shared by Station/app launch scripts.
- UI labels for non-full modes.
- Tests ensuring mock/demo modes never call cloud providers.

### Acceptance criteria

- No test depends on real cloud or heavy model unless explicitly requested.
- `full` mode is the only mode that combines cloud reasoning and LuxTTS.
- Logs/status clearly show the active mode.

### Tests

- Unit tests for mode parsing and provider selection.
- Browser and MacStation demo smoke.
- Negative tests proving no cloud calls in mock/demo mode.

## Item 6 — Harden security/privacy

### Already done

- `docs/product/PRIVACY_AND_SECURITY.md`.
- `docs/product/KNOWN_LIMITATIONS.md`.
- Public secret scan.
- API keys/private samples excluded from repo.
- Existing client-side redaction/pseudonymization path.

### Remaining deliverables

- Browser local-state encryption or documented explicit “unsafe demo/browser”
  mode until encryption is complete.
- Safety regression corpus:
  - PII requests;
  - secrets;
  - unsafe meetings;
  - self-harm/violence;
  - medical/legal/financial advice;
  - adult content;
  - prompt injection by child or parent guidance.
- Privacy-network test plan:
  - voice samples only to Station;
  - LLM request excludes raw voice and real kid identifiers;
  - no API keys in URLs/logs.
- Optional pre-commit or local secret-scan helper.

### Acceptance criteria

- Browser storage risk is reduced or explicitly gated.
- Safety corpus passes deterministically for mock/provider test paths.
- Privacy docs match implementation.

### Tests

- Unit tests for redaction/pseudonymization.
- Provider prompt snapshot tests without secrets.
- Safety corpus tests.
- Log/URL secret scan in QA artifacts.

## Item 7 — Better release artifacts

### Already done

- `make public-artifacts` builds local artifacts outside the repo.
- macOS zip/DMG, Android APK, iOS simulator/device app outputs exist when local
  prerequisites are available.

### Remaining deliverables

- `make release-local` or `tools/release/create_release_bundle.sh`.
- SHA-256 checksums for all artifacts.
- `RELEASE_NOTES.md` generated from template.
- GitHub release automation:
  - tag;
  - upload artifacts;
  - upload checksums;
  - mark unsigned/dev artifacts clearly.
- Optional signing/notarization path:
  - signed macOS app;
  - notarized DMG;
  - Android release signing;
  - iOS signing/provisioning instructions.

### Acceptance criteria

- A GitHub visitor can download a release bundle and see exactly what each
  artifact is.
- Checksums are published with artifacts.
- Unsigned/dev artifacts are labeled honestly.

### Tests

- Release bundle structure test.
- Checksum verification test.
- Packaged app smoke from release artifact.

## Item 8 — MacStation reliability dashboard

### Status

Not done.

### Deliverables

- Add a diagnostics panel in Station:
  - setup phase;
  - service health;
  - active mode;
  - data directory;
  - artifact/runtime directory;
  - host URL;
  - LAN pairing status;
  - LuxTTS worker status;
  - last error.
- Buttons:
  - copy diagnostics;
  - open log folder;
  - retry setup;
  - reset runtime only;
  - reset app data;
  - stop/start local host.
- Structured diagnostic JSON endpoint from Rust host:

```text
GET /api/v1/diagnostics
```

- Station UI should consume both shell setup state and host diagnostics.

### Acceptance criteria

- User can answer “what failed?” without opening Terminal.
- Diagnostics never include secrets, prompt text, raw child text, or audio bytes.
- Reset/retry actions are explicit and confirmation-gated where destructive.

### Tests

- Swift setup-state reducer/unit tests where possible.
- Rust diagnostics endpoint tests.
- Packaged Station screenshot/log smoke.
- Secret scan over diagnostics output.

## Item 9 — Add more E2E scripted tests

### Already done

- Local quality gate.
- MacStation API smoke.
- MacStation LuxTTS E2E.
- MacStation demo voice E2E.
- Android install/launch and pairing smokes.
- iOS simulator launch smoke.
- Browser and Mac client render smokes.

### Remaining deliverables

- Full UI journey automation:
  - first launch;
  - configure parent;
  - pair Station;
  - create kid;
  - create character;
  - upload sample or demo voice;
  - preview/approve;
  - enter child mode;
  - send message;
  - receive response/audio;
  - navigate back;
  - delete character/history/all data.
- Run matrix:
  - browser demo;
  - Mac client demo;
  - Android debug demo;
  - iOS simulator demo where feasible.

### Acceptance criteria

- Core user journeys are runnable by script.
- Tests are stable enough for local pre-release gates.
- Heavy LuxTTS tests remain opt-in, not mandatory in CI.

### Tests

- Playwright or browser automation for web.
- ADB UIAutomator for Android.
- `xcrun simctl`/XCUITest-lite smoke for iOS simulator.
- Rust API journey tests for Station.

## Item 10 — Document limitations clearly

### Status

Done.

### Already done

- `docs/product/KNOWN_LIMITATIONS.md`.
- README links to limitations.
- README/demo docs identify synthetic voice mode honestly.

### Ongoing maintenance

- Update limitations after every major hardening change.
- Remove limitations only after tests/evidence prove they are resolved.

## Milestone plan

### Milestone A — Station reliability

Includes items 1 and 8.

Deliver:

- Station diagnostics panel.
- Setup phase model.
- Retry/reset/open logs/copy diagnostics.
- Host diagnostics endpoint.
- Basic failure-injection tests.

Exit gate:

```sh
make public-repo-check
make doctor
cargo test -p plushpal-desktop-host --features native-runtime
qa/automation/run_local_quality_gate.sh
```

### Milestone B — Demo and mode matrix

Includes items 2 and 5.

Deliver:

- `make run-demo`.
- Full demo kid/character/reasoning/voice flow.
- Explicit mode config and UI labels.
- Mock/demo tests proving no cloud/model calls.

Exit gate:

```sh
make run-demo
qa/automation/macstation_api_smoke.py --voice-engine demo --synthesize
qa/automation/run_local_quality_gate.sh
```

### Milestone C — LuxTTS setup hardening

Completes item 1’s model/runtime side.

Deliver:

- Version/check markers.
- Repair partial setup.
- Better retry/resume.
- Worker health and model cache diagnostics.

Exit gate:

```sh
make public-artifacts
qa/automation/macstation_api_smoke.py --voice-engine luxtts --synthesize --sample ...
```

### Milestone D — E2E journey automation

Completes item 9.

Deliver:

- Browser/Mac client scripted journey.
- Android scripted journey.
- iOS simulator best-effort journey.
- Stable result artifacts under `~/Downloads/PlushPal/test-results`.

Exit gate:

```sh
qa/automation/run_local_quality_gate.sh
qa/automation/browser_demo_journey.sh
qa/automation/android_demo_journey.sh
qa/automation/ios_simulator_demo_journey.sh
```

### Milestone E — Release bundle

Completes item 7.

Deliver:

- Release bundle script.
- Checksums.
- Release notes template.
- GitHub release helper.
- Clear unsigned/signed labeling.

Exit gate:

```sh
make public-artifacts
make release-local
shasum -a 256 -c ~/Downloads/PlushPal/artifacts/SHA256SUMS
```

### Milestone F — Deeper privacy and safety

Completes item 6’s remaining work.

Deliver:

- Browser storage hardening decision/implementation.
- Safety regression corpus.
- Prompt/redaction snapshot tests.
- Privacy-network/log scan tests.

Exit gate:

```sh
make public-repo-check
cargo test --workspace
cd apps/android/flutter_app && flutter test
qa/automation/run_safety_corpus.sh
```

## Definition of done for all 10 items

All 10 items are complete when:

- fresh-clone README flow works;
- full demo mode works without secrets/heavy model;
- full LuxTTS mode works on supported Mac;
- Station explains failures and provides retry/reset/logs;
- CI protects public clone health;
- local quality gate is green;
- release artifacts have checksums and clear labels;
- privacy/safety docs match implementation;
- core browser/Mac/Android/iOS journeys have automated evidence;
- no private samples, secrets, or generated artifacts are tracked.
