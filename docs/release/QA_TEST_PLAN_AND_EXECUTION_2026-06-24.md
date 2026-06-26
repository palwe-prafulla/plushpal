# PlushBuddy QA Test Plan and Execution Report

Date: 2026-06-24  
Scope: Android app, iPhone app, Mac app, Web app, and MacStation voice server.

## Executive summary

The shared core and build pipeline are in good shape, but the product is not yet "fully end-to-end tested" across every surface.

What is well covered today:

- Rust shared core, MacStation backend, security boundaries, storage, local attach/external pairing, voice lifecycle routes, and model/service orchestration are covered by the Rust workspace test suite.
- The shared Flutter client logic used by Android, iPhone, Web, and Mac client has unit/widget coverage for onboarding, parent setup, character management, voice state handling, child mode, conversation UI, history/privacy flows, and the known "new character inherits old voice" regression.
- Android APK, iPhone simulator app, unsigned iPhone device app, Web build, and macOS packaged apps all build successfully.
- Browser support files and web-specific JavaScript adapters have dedicated Node tests.

What is not fully proven yet:

- Android physical-device end-to-end testing was not run in this pass because no Android device or emulator was visible to Flutter/ADB at test time.
- iPhone simulator build passes, but simulator-only testing is not equivalent to a real iPhone for camera QR scanning, microphone behavior, local-network permissions, and real audio playback quality.
- Web app release build passes, but the local static-server browser smoke test was not a valid full Web E2E run because the web client expects MacStation API routes. Static assets loaded, but `/api/v1/status` and voice status returned 404 without MacStation. Web E2E must be rerun through MacStation.
- MacStation packaging passes, but a full GUI launch test with LuxTTS health, browser/Mac local attach, Android/iPhone QR pairing, voice upload, profile creation, preview, approval, and client playback should still be run as a release-candidate checklist.

## Current execution results

| Area | Command / check | Result | Notes |
|---|---:|---|---|
| Flutter static analysis | `cd apps/android/flutter_app && flutter analyze` | PASS | No analyzer issues. |
| Flutter unit/widget tests | `cd apps/android/flutter_app && flutter test` | PASS | 34 Flutter tests passed. |
| Web adapter tests | `node --test test/audio_normalization_test.js test/plushpal_backend_web_test.mjs` | PASS | 6 Node tests passed. |
| Web release build | `flutter build web --release --pwa-strategy=none --no-web-resources-cdn` | PASS | Built `apps/android/flutter_app/build/web`. |
| Web browser smoke | Serve `build/web` on `127.0.0.1:4173` and open in browser | INCONCLUSIVE / NEEDS MACSTATION | Static assets loaded and title was `PlushBuddy`; no startup console errors; `/api/v1/status` and voice status returned 404 because the static server was not MacStation. |
| Rust workspace tests | `cargo test --workspace` | PASS | Rust application/domain/MacStation/storage/security tests passed. |
| Product layout | `make test-product-layout` | PASS | Packaged product layout checks passed. |
| Android APK | `make android-apk` | PASS | Debug APK generated under `apps/android/flutter_app/build/app/outputs/flutter-apk/app-debug.apk`. |
| iPhone simulator build | `make ios-simulator` | PASS | Built `apps/android/flutter_app/build/ios/iphonesimulator/Runner.app`. |
| iPhone unsigned device build | `make ios-device` | PASS | Built unsigned `apps/android/flutter_app/build/ios/iphoneos/Runner.app`. |
| macOS packaging | `make package-macos` | PASS | Generated `PlushBuddy Station.app`, `PlushBuddy.app`, zip, and dmg artifacts. Current public-build output path is `~/Downloads/PlushPal/artifacts/macos`. |

## E2E/smoke execution update after Android device connection

After a Pixel 10 Pro was connected over USB debugging, additional product-level smoke/E2E automation was added under `qa/automation/` and executed.

| Area | Script / check | Result | Evidence |
|---|---:|---|---|
| Android real device install/launch | `qa/automation/android_device_smoke.sh` | PASS | `qa/results/android-device-20260624-194217`; installed APK, cleared app data, launched on Pixel 10 Pro, captured screenshot/UI dump with expected PlushBuddy welcome/settings text. |
| Android real device navigation | UIAutomator tap/dump smoke | PASS | `qa/results/android-device-nav-20260624-194707`; tapped `Parent Settings`, verified parent setup screen and setup sections. |
| Android Station pairing | `qa/automation/android_station_pairing_smoke.sh` | PASS | `qa/results/android-station-pairing-20260624-201224`; started temporary Station, exchanged bootstrap, used ADB reverse and debug-only pairing intent to save Station pairing on the Pixel. |
| iPhone simulator install/launch | `qa/automation/ios_simulator_smoke.sh` | PASS | `qa/results/ios-simulator-20260624-194316`; built, booted simulator, installed, launched, captured screenshot. |
| MacStation API smoke | `qa/automation/macstation_api_smoke.py` | PASS | `qa/results/macstation-api-20260624-194153`; isolated host startup, health, bootstrap auth, status, parent PIN, character save/list. |
| MacStation M4A enrollment smoke | `qa/automation/macstation_api_smoke.py --sample ...` | PASS | `qa/results/macstation-api-20260624-195724`; enrolled Sheru/Jenna/Buddy M4A samples, approved voices, verified post-approval alias-scoped profile IDs are stable and unique. |
| MacStation full LuxTTS voice E2E | `qa/automation/macstation_api_smoke.py --voice-engine luxtts --synthesize --sample ...` | PASS | `qa/results/macstation-api-20260624-195253`; LuxTTS health ready, enrolled/approved Sheru/Jenna/Buddy, synthesized WAV responses for all three characters. |
| MacStation live Gemini reasoning | `qa/automation/macstation_live_reasoning_smoke.mjs` | PASS | `qa/results/macstation-reasoning-20260624-201207`; used a local environment secret, verified Gemini engine readiness, command WebSocket event flow, and non-empty structured response without logging the key. |
| Web app through MacStation | In-app browser against real Station bootstrap URL | PASS | `qa/results/web-station-20260624-1946`; Station-served client rendered the PlushBuddy welcome/setup UI with no browser console errors. |
| Mac client app | Packaged `PlushBuddy.app` launched with `PLUSHBUDDY_STATION_URL` | PASS | `qa/results/mac-client-20260624-194618`; Mac client loaded Station URL and logged navigation finished. |
| Packaged MacStation shell | `open ~/Downloads/PlushPal/artifacts/macos/PlushBuddy Station.app` | PASS | `qa/results/macstation-packaged-20260624-194727`; packaged Station launched and screenshot/log artifact was captured. |
| Local automated quality gate | `qa/automation/run_local_quality_gate.sh` | PASS | `qa/results/local-quality-20260624-201250`; `cargo test --workspace`, Flutter analyze/test, web Node tests, product layout test all passed after the Station and Gemini fixes. |
| Focused host voice tests | `cargo test -p plushpal-desktop-host --features native-runtime voice -- --nocapture` | PASS | Verified native voice-engine process wrappers and parent-gated voice enrollment/approval/speech tests after the Station profile-id fix. |

### Issue found and fixed during E2E

The full Station voice E2E exposed a public API consistency bug:

- `Buddy` enrollment returned an alias-derived profile id;
- later `voice/status` and `characters` could return an internal `voice-profile-primary-character` id for the same character when Buddy was also the configured default character.

The Station API was fixed so character-specific voice status and character listing always expose alias-derived public profile IDs. The E2E script was tightened to fail if an enrolled profile ID changes after approval.

The live Gemini smoke also exposed a reliability issue:

- Gemini could return a non-JSON preamble or truncated structured response under the previous `temperature=0.7` / `maxOutputTokens=180` settings.
- Station's Gemini generation config was hardened to `temperature=0.2` and `maxOutputTokens=400`, and the live reasoning smoke now passes.

## Device availability during this test pass

| Device target | Availability | Impact |
|---|---|---|
| macOS desktop | Available | macOS build/package checks could run. |
| Chrome/Web | Available | Web build and browser smoke could run. |
| Android phone | Not visible to `flutter devices` / `adb devices` in this pass | Android APK build is verified, but real-device E2E was not run. |
| Android emulator | Not visible | Same as Android phone. |
| iPhone simulator | Build target available | Compile/build verification works; simulator E2E should be run next. |
| Physical iPhone | Not available | Real camera/mic/local-network/audio behavior cannot be fully certified. |

## Platform readiness assessment

| Platform | Current confidence | Why |
|---|---|---|
| Android app | Medium-high | Shared Flutter tests and APK build pass. Real Pixel install/launch, first settings navigation, and debug-only Station pairing pass. Full manual Android flow still needs camera QR scan, Android file picker M4A upload, preview playback, approval, live typed/spoken child conversation, and history/delete validation from the device UI. |
| iPhone app | Medium for build; low-medium for behavior | iOS simulator and unsigned device builds pass. Most shared UI logic is covered by Flutter tests. Simulator can test onboarding/navigation/forms/history, but not all real hardware behavior. |
| Web app | Medium-high | Web build and web adapter tests pass. Station-served browser smoke now renders PlushBuddy welcome/setup UI. Full Web form/upload/conversation E2E still needs scripted UI coverage. |
| Mac app client | Medium-high | macOS package artifacts are generated and packaged `PlushBuddy.app` loaded the Station UI successfully. Full form/upload/conversation E2E still needs scripted GUI coverage. |
| MacStation | High | Rust tests cover APIs/security/state strongly. Packaged Station launches. Full LuxTTS E2E with Sheru/Jenna/Buddy M4A enrollment, approval, unique profile IDs, and WAV synthesis passed. Live Gemini command/WebSocket reasoning smoke also passed. |

## Automated test inventory

### Flutter client tests

Existing tests:

- `apps/android/flutter_app/test/app_state_test.dart`
- `apps/android/flutter_app/test/backend_client_test.dart`
- `apps/android/flutter_app/test/platform_bridge_test.dart`
- `apps/android/flutter_app/test/widget_test.dart`

Covered behaviors include:

- onboarding fail-closed states;
- parent profile validation and setup;
- child mode entry/exit state handling;
- typed and spoken question flows;
- empty prompt handling;
- model-not-ready states;
- character creation, deletion, refresh, and switching;
- voice preview, approval, scoped voice actions, and voice-profile isolation;
- conversation ordering and history review/delete flows;
- privacy/delete-all-data flows;
- platform bridge boundaries for speech and secret references.

### Web JavaScript tests

Existing tests:

- `apps/android/flutter_app/test/audio_normalization_test.js`
- `apps/android/flutter_app/test/plushpal_backend_web_test.mjs`

Covered behaviors include:

- browser audio normalization helper behavior;
- web backend local-storage behavior;
- Station-only voice profile API behavior in the browser backend adapter.

### Android native test

Existing test:

- `apps/android/flutter_app/android/app/src/test/kotlin/com/plushpal/plushpal_ui/ParentProfileValidatorTest.kt`

Covered behavior:

- native-side parent profile validation logic.

### Rust workspace tests

Covered crates include:

- `application`
- `audio_core`
- `character_voice`
- `cloud_provider`
- `curated_search`
- `desktop_gateway`
- `desktop_host`
- `device_capability`
- `encrypted_storage`
- `llama_native_ffi`
- `local_llm_llamacpp`
- `mobile_bridge`
- `model_lifecycle`
- `parent_controls`
- `policy_engine`
- `session_engine`

Important behaviors covered:

- encrypted storage and parent profile behavior;
- policy/guardrails;
- session/conversation logic;
- cloud provider abstraction;
- desktop host health/status/bootstrap routes;
- host/origin/body security;
- static asset safety;
- websocket authorization;
- voice enrollment/preview/approval/speak/delete parent gates;
- imported audio conversion and paired voice-station path;
- model install command validation.

## Full functional test plan

These are the acceptance tests that should be run before calling the MVP release-ready.

### 1. First launch and setup

| ID | Case | Expected result | Android | iPhone sim | Web | Mac app | MacStation |
|---|---|---|---|---|---|---|---|
| SETUP-001 | Fresh install / clear local data | App opens welcome/home state with clear setup needs | Needed | Needed | Needed | Needed | N/A |
| SETUP-002 | Open Settings from home | Parent PIN prompt appears only for entering parent settings | Needed | Needed | Needed | Needed | N/A |
| SETUP-003 | Create parent PIN | PIN is saved securely; settings unlocks | Covered by tests; device E2E needed | Simulator E2E needed | Browser E2E needed | Mac E2E needed | N/A |
| SETUP-004 | Wrong PIN | Visible unauthorized/locked message; no silent navigation | Needed | Needed | Needed | Needed | N/A |
| SETUP-005 | Leave Settings and return | Home state updates immediately without stale setup warnings | Needed | Needed | Needed | Needed | N/A |

### 2. Settings navigation

| ID | Case | Expected result |
|---|---|---|
| NAV-001 | Settings root shows categories | Parent profile, pairing, model provider, kids/characters, history/privacy are separate, clear sections. |
| NAV-002 | Open one category | Only that category opens; it does not show unrelated settings. |
| NAV-003 | Back navigation | Back returns to previous screen, not a stale popup or home unexpectedly. |
| NAV-004 | Save action | Success/failure feedback is visible. |
| NAV-005 | Dangerous actions | Delete kid, delete character, delete history, delete all data require confirmation. |

### 3. Kid profiles

| ID | Case | Expected result |
|---|---|---|
| KID-001 | Add first kid | Kid appears immediately on home/settings without refresh workaround. |
| KID-002 | Add up to four kids | Fifth kid is blocked with a friendly message. |
| KID-003 | Add kid photo from phone/gallery | Large photos are accepted and resized/cropped locally. |
| KID-004 | Edit kid birthdate | Derived age updates guardrail/persona context. |
| KID-005 | Delete kid | Confirmation appears; kid and linked local data are removed or handled clearly. |

### 4. Character profiles

| ID | Case | Expected result |
|---|---|---|
| CHAR-001 | Add character under a kid | Character appears under the correct kid immediately. |
| CHAR-002 | Add up to three characters per kid | Fourth character is blocked with a friendly message. |
| CHAR-003 | Add character photo | Large photo is resized/cropped; no user-visible file-size failure for normal phone photos. |
| CHAR-004 | Add personality/likes/favorites | Saved values are used in the LLM prompt/persona context. |
| CHAR-005 | Set character persona age | Persona age defaults to child age if omitted; otherwise can be 2 years up to child age. |
| CHAR-006 | New character starts with no voice | It must not inherit an existing character voice profile. |
| CHAR-007 | Delete character | Requires confirmation and immediately updates home/settings. |

### 5. Voice profile lifecycle

| ID | Case | Expected result |
|---|---|---|
| VOICE-001 | Upload M4A sample | Accepted, converted/normalized, and sent to MacStation for profile creation. |
| VOICE-002 | Upload WAV/MP3/AAC/OGG/WebM | Supported formats are accepted or rejected with explicit reason. |
| VOICE-003 | Upload large/long sample | App shows progress; no crash or return-to-setup loop. |
| VOICE-004 | Voice profile creation progress | Progress/status remains visible until success/failure. |
| VOICE-005 | Preview unapproved voice | Preview plays the current character voice only. |
| VOICE-006 | Cancel file picker during preview/reupload | Existing pending/approved voice state is preserved. |
| VOICE-007 | Approve voice | Approval succeeds visibly and enables child mode for that character. |
| VOICE-008 | Reupload voice | Old profile is replaced only after new profile is created/approved; failures do not corrupt old profile. |
| VOICE-009 | Multiple characters with different samples | Sheru, Jena, and Buddy each retain separate profile IDs and previews. |
| VOICE-010 | Station deletes transient uploaded samples | MacStation does not retain raw uploaded samples after profile creation unless LuxTTS requires a retained reference; retained data must be profile-scoped. |

### 6. MacStation setup, local attach, and external pairing

| ID | Case | Expected result |
|---|---|---|
| STATION-001 | First launch | Shows setup progress rows and does not fail silently. |
| STATION-002 | Already installed dependencies | Reuses existing install; startup is fast and stable. |
| STATION-003 | LuxTTS health | Voice engine health shows ready only after model runtime is usable. |
| STATION-004 | Local browser attach | Browser opened from Station exchanges bootstrap token once, removes token from URL, and shows green Magic Voice Box status without QR scanning. |
| STATION-005 | Local Mac client attach | Mac client opened from Station auto-attaches to the same local Station session without QR scanning. |
| STATION-006 | External pairing QR | QR code displays for Android/iPhone without requiring URL copy/paste. |
| STATION-007 | Android/iPhone scan QR | External client pairs, saves Station connection, and shows green status. |
| STATION-008 | Invalid/expired QR | Client shows friendly failure and Station can generate a new QR. |
| STATION-009 | Station unreachable | Client clearly shows unavailable voice server, not a generic setup failure. |
| STATION-010 | Quit Station | Services stop cleanly; installed assets remain on disk. |

### 7. Model provider/API key

| ID | Case | Expected result |
|---|---|---|
| LLM-001 | Save Gemini API key | Key is encrypted/securely stored and never shown in plaintext after save. |
| LLM-002 | Save OpenAI API key | Same secure behavior for OpenAI provider. |
| LLM-003 | Missing key | Child conversation cannot start or clearly prompts parent setup. |
| LLM-004 | Invalid key | Visible error; no app crash; child input re-enables safely. |
| LLM-005 | Provider switch | App uses selected provider for new conversations. |
| LLM-006 | Personal info redaction | Child real name is replaced with pseudonym before cloud LLM call; local UI restores personal touch if needed. |

### 8. Child mode conversation

| ID | Case | Expected result |
|---|---|---|
| CHILD-001 | Select kid and character on home | Home has one clear kid selector and one clear active-character selector. |
| CHILD-002 | Enter child mode | Starts the selected kid-character conversation. |
| CHILD-003 | Exit child mode | Exit/back returns to home without requiring parent PIN. |
| CHILD-004 | Type message | Message appears in chat-style UI; input disables while response/TTS is pending. |
| CHILD-005 | Voice response timing | Text and voice response are presented together or in a way that does not feel out-of-sync. |
| CHILD-006 | Mic permission first time | Permission grant does not kick user back to home. |
| CHILD-007 | Mic busy / denied | Friendly error such as "microphone is in use" instead of repeated "did not catch that." |
| CHILD-008 | Child pauses mid-sentence | Speech capture waits long enough for child-paced conversation. |
| CHILD-009 | Stop/cancel talking | User can stop current listening or response playback. |
| CHILD-010 | Latency | Warm voice generation should avoid model reload per turn; target should be measured and tracked. |
| CHILD-011 | Persona correctness | Toy answers in toy persona and age-appropriate style, while still answering factual questions correctly. |

### 9. Conversation history and privacy

| ID | Case | Expected result |
|---|---|---|
| HIST-001 | Per kid-character history | History is scoped under each character for each kid. |
| HIST-002 | Continue prior thread | Re-entering a kid-character can continue the correct conversation. |
| HIST-003 | Delete character history | Deletes only that character's history. |
| HIST-004 | Delete all conversations | Outer setting with confirmation deletes all conversations. |
| HIST-005 | Delete all local data | Confirmation required; all local profile/history/key data is removed. |

### 10. Platform-specific E2E tests

#### Android physical device

Required before release:

1. Install APK.
2. Fresh setup parent PIN.
3. Pair with MacStation via QR.
4. Save Gemini/OpenAI key.
5. Add kid with photo.
6. Add Sheru, Jena, Buddy with separate M4A samples from phone Downloads.
7. Preview and approve each voice.
8. Verify no character inherits another character's voice.
9. Enter child mode and test typed prompt.
10. Test microphone permission and spoken prompt.
11. Verify response text, voice playback, disabled input while pending, exit navigation.
12. Verify history under the correct kid-character.
13. Delete one character and confirm UI updates immediately.
14. Delete all data and repeat setup.

#### iPhone simulator

Can test:

1. Launch and first-run UI.
2. Settings navigation.
3. PIN setup and validation.
4. Kid/character creation.
5. Form validation.
6. Provider/key UI using fake keys.
7. Conversation UI with mocked/stubbed backend.
8. History/delete flows.
9. Basic audio playback API if using generated local test audio.

Cannot fully certify in simulator:

- real camera QR scanning;
- real mic capture behavior under iOS hardware conditions;
- local-network permission behavior on a real Wi-Fi network;
- file picker behavior against real user recordings/photos;
- speaker quality/latency perception;
- physical-device backgrounding/thermal/battery behavior.

#### Web app

Required before release:

1. Start PlushBuddy Station.
2. Open the browser client from Station.
3. Verify automatic local attach completes without QR scanning and the Magic Voice Box status is green.
4. Verify visible home/welcome render.
5. Verify Settings navigation.
6. Add kid/character/photo.
7. Upload M4A sample.
8. Preview/approve voice.
9. Start typed child conversation.
10. Verify history and delete flows.
11. Refresh browser and verify persistence.
12. Clear site data and verify fresh setup.

#### Mac client app

Required before release:

1. Start PlushBuddy Station.
2. Launch the Mac client from Station.
3. Verify automatic local attach completes without QR scanning and the Magic Voice Box status is green.
4. Repeat the browser settings, character, voice upload, preview, approval, typed conversation, history, and delete flows.

Required before release:

1. Open packaged `PlushBuddy Station.app`.
2. Wait for health rows to become green.
3. Click "Open PlushBuddy app".
4. Verify separate `PlushBuddy.app` opens.
5. Run same client flow as Web app.
6. Quit/reopen and verify state persists.
7. Verify no keychain prompts appear mid-conversation after startup unlock.

## Recommended next test automation work

1. Add Flutter integration tests that run the same scripted flow on Android emulator and iOS simulator.
2. Add a Station mock mode so client E2E can test voice states without running LuxTTS.
3. Expand the MacStation E2E smoke script to optionally launch the packaged Station shell, not only the Rust host.
4. Add Web Playwright-style tests against the Station-served app for settings/kids/characters/history navigation.
5. Add golden/screenshot tests for the simplified home/settings/character/child-mode screens.
6. Add a release checklist requiring real Android phone E2E with Sheru/Jena/Buddy samples.

## Bottom line

The implementation has strong automated coverage for the shared product logic and backend safety boundaries. The builds are also healthy across Android, iOS, Web, and macOS packaging. After connecting the Android phone, real Android launch/navigation smoke, Station-served Web smoke, Mac client smoke, packaged Station smoke, iPhone simulator launch, and full LuxTTS Station E2E were added and executed.

The remaining gap is now narrower: deeper client UI E2E and live conversation QA:

- Android real-device full UI flow: camera QR scan, file picker M4A upload, preview playback, approval, live typed/spoken conversation, history, delete/recreate flows.
- Web/Mac client full UI flow against Station: settings, kids, characters, upload, preview, approve, typed conversation, history.
- Live Gemini reasoning is now tested at the MacStation command layer. Live Gemini through the Android/iPhone/Web/Mac client UI still needs manual or deeper UI automation because API-key entry, file picker, microphone, and audio playback are OS/UI surfaces.
- iPhone simulator settings/navigation flow, followed later by physical iPhone validation for camera/mic/local-network/audio.
