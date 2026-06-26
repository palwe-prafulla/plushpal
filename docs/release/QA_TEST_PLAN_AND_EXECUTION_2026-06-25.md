# PlushBuddy QA Test Plan and Execution Report

Date: 2026-06-25  
Scope: public-repo artifact build, MacStation, Mac client, browser client,
Android real device, iPhone simulator, shared unit tests, and LuxTTS voice E2E.

## Executive summary

The current public-repo candidate is green for all local automated checks that
can run without a cloud provider key.

The tested release shape is:

- source checkout stays clean;
- public build/test outputs are written under `~/Downloads/PlushPal`;
- `make public-artifacts` builds MacStation, Mac client, Android APK, iPhone
  simulator app, and unsigned iPhone device app;
- MacStation can enroll/approve/synthesize separate LuxTTS voices for the three
  current M4A samples;
- Android real-device install/launch and debug Station pairing pass;
- iPhone simulator install/launch passes;
- browser and Mac client attach to packaged MacStation.

Live Gemini/OpenAI conversation through the UI was not rerun in this pass
because the local Gemini key file was intentionally deleted before public-repo
hygiene checks, and no provider key was present in the environment.

## Artifact locations

Public artifacts:

```text
~/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app
~/Downloads/PlushPal/artifacts/macos/PlushBuddy.app
~/Downloads/PlushPal/artifacts/macos/PlushBuddy-0.1.0-macos.dmg
~/Downloads/PlushPal/artifacts/macos/PlushBuddy-0.1.0-macos.zip
~/Downloads/PlushPal/artifacts/android/PlushBuddy-debug.apk
~/Downloads/PlushPal/artifacts/ios/PlushBuddy-iPhoneSimulator.app
~/Downloads/PlushPal/artifacts/ios/PlushBuddy-iPhoneOS-unsigned.app
```

QA evidence:

```text
~/Downloads/PlushPal/test-results
```

Private local samples were moved outside the repository:

```text
~/Downloads/PlushPal/private/audio-samples
```

## Current execution results

| Area | Command / check | Result | Evidence |
|---|---|---:|---|
| Public artifact build | `make public-artifacts` | PASS | `~/Downloads/PlushPal/artifacts` |
| Local quality gate | `qa/automation/run_local_quality_gate.sh` | PASS | `local-quality-20260625-212532` |
| MacStation API smoke | `qa/automation/macstation_api_smoke.py` | PASS | `macstation-api-20260625-181750` |
| MacStation demo voice E2E | `qa/automation/macstation_api_smoke.py --voice-engine demo --synthesize --sample ...` | PASS | `macstation-api-20260625-212730`; synthetic fast-path validates enrollment/approval/synthesis plumbing without LuxTTS. |
| MacStation LuxTTS E2E | `qa/automation/macstation_api_smoke.py --voice-engine luxtts --synthesize --sample ...` | PASS | `macstation-api-20260625-182107` |
| Packaged MacStation launch/readiness | Packaged app launch/log readiness smoke | PASS | `macstation-packaged-20260625-182639` |
| Browser client through packaged Station | Station-served Flutter UI render smoke | PASS | `packaged-station-clients-20260625-182741/browser-report.json` |
| Mac client through packaged Station | Packaged `PlushBuddy.app --station-url ...` | PASS | `packaged-station-clients-20260625-182741/mac-client-status.txt` |
| Android real device install/launch | `qa/automation/android_device_smoke.sh` | PASS | `android-device-20260625-183045` |
| Android Station pairing | `qa/automation/android_station_pairing_smoke.sh` | PASS | `android-station-pairing-20260625-183121` |
| iPhone simulator install/launch | `qa/automation/ios_simulator_smoke.sh` | PASS | `ios-simulator-20260625-183045` |

## Local quality gate coverage

`qa/automation/run_local_quality_gate.sh` runs from an external test workspace
and writes logs under `~/Downloads/PlushPal/test-results`.

It covers:

- `cargo test --workspace`;
- Flutter static analysis;
- Flutter unit/widget tests;
- browser JavaScript adapter tests;
- packaged product layout checks.

## MacStation LuxTTS E2E coverage

The full voice E2E used the three local M4A samples:

- Sheru;
- Jenna;
- Buddy.

For each character, the script verified:

1. parent PIN configuration;
2. character save/list;
3. M4A voice enrollment;
4. parent approval;
5. stable post-approval profile ID;
6. unique profile IDs across characters;
7. WAV synthesis through LuxTTS.

## Platform notes

### Android

The Android real-device smoke was run against the connected Pixel 10 Pro. It
installed the externally built APK, cleared app data, launched the app, captured
UI dump/screenshot evidence, and verified expected PlushBuddy welcome/settings
text. The debug Station-pairing smoke also passed using ADB reverse and the
debug-only pairing intent.

### iPhone

The iPhone simulator smoke installed and launched the externally built simulator
app. Real iPhone camera QR pairing, microphone, file picker, local-network
permission, and playback behavior still require Apple signing/provisioning and a
physical device.

### Browser

The browser smoke loaded the packaged Station bootstrap URL in Google Chrome and
verified the PlushBuddy title plus Flutter-rendered UI. A previous CSP
`base-uri 'none'` warning was fixed by allowing `base-uri 'self'`, which matches
Flutter's local `<base href="/">` behavior while still blocking external base
URI injection.

### Mac client

The packaged Mac client was launched with `--station-url` against packaged
MacStation. It stayed alive and logged successful navigation.

## Public repository hygiene

Completed before this report:

- deleted local `gemiapi`;
- moved private audio samples out of the repository;
- expanded `.gitignore` for secrets, model caches, venvs, local samples, build
  outputs, QA results, and generated platform files;
- moved generated build/test outputs to `~/Downloads/PlushPal`;
- added `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, and `THIRD_PARTY.md`;
- added/updated public build and QA scripts to use external artifact paths.

## Remaining gaps before a product release

These are not blockers for creating the public GitHub repository, but they are
still product-release work:

- add production signing/notarization for MacStation and Mac client;
- add Android release signing;
- add iPhone physical-device E2E with Apple signing/provisioning;
- rerun live Gemini/OpenAI conversation UI E2E with a fresh local provider key;
- improve LuxTTS latency instrumentation;
- add production privacy labels and store-distribution metadata.
