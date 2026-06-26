# Local verification record — 2026-06-19

Scope: development/private-beta evidence generated on Apple M4 Pro with macOS. This is not a signed release attestation because the repository has not yet been committed or tagged and no distribution identity was supplied.

## Passed gates

- Rust 1.86.0 formatting and workspace Clippy with warnings denied.
- 114 Rust unit/integration tests.
- Native llama.cpp ABI build/conformance with Metal and Accelerate.
- Apple key-vault ABI build/conformance.
- Flutter static analysis, 27 Flutter tests, and release web build with bundled Roboto assets.
- Swift platform-plugin syntax parse and browser-bridge JavaScript syntax check.
- Static API-key-pattern scan outside generated/vendor trees.
- Exact Qwen3 1.7B Q8_0 artifact: 1,834,426,016 bytes; SHA-256 `061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a`.
- Release-mode model activation, Qwen chat-template rendering, strict structured generation, post-generation safety orchestration, and active cancellation.
- The feature-gated representative-model smoke target is compiled by the release gate. Its live run returned an age-appropriate local answer for “Why is the sky blue?” with `suggest_trusted_adult: false`, then passed active cancellation.
- Embedded loopback browser flow: one-time bootstrap, model-ready status, parent setup, local model response, and wrong-PIN rejection.
- Packaged-host persistence flow: SQLCipher profile creation, full process restart, restored age/name/PIN authorization, PIN-authorized delete-all, and immediate unconfigured status.
- Parent character traits/guidance editing plus session-only and encrypted 1/7/30-day transcript retention, review, expiry, and deletion flows.
- Parent voice lifecycle through the real loopback API: a 20-second mono 16-bit 16 kHz WAV was consent-validated, enrolled, reported as awaiting approval, previewed with sample-conditioned local synthesis, approved, used for child-mode speech, and deleted.
- Google Recorder-style M4A import smoke: a 20-second AAC-in-M4A fixture decoded in the browser from `audio/mp4`, then the production `audio_normalization.js` converted it locally to a 961,388-byte mono 24 kHz 16-bit `RIFF/WAVE` file for the existing encrypted enrollment path.
- User-provided M4A samples `Buddy.m4a`, `Jenna.m4a`, and `Sheru.m4a` decode in the browser. Follow-up voice-quality tuning now preserves future browser enrollment references up to 40 seconds as mono 24 kHz 16-bit WAV files, because longer clean same-speaker samples can help Chatterbox retain more nuance.
- Local cleanup stage was added to browser enrollment normalization: strongest-window selection, high-pass filtering, stationary spectral noise reduction, soft gating, and loudness normalization before encrypted storage. Cleaned references generated from the real samples:
  - `/tmp/plushpal-cleaned-refs/Buddy-cleaned.wav`, 1,556,396 bytes, 32.42 seconds, SHA-256 `64b8d25276ca1b786bf3e109a8c23d8ef6575e6d9678f4ff028b69f60a97cfee`.
  - `/tmp/plushpal-cleaned-refs/Jenna-cleaned.wav`, 1,789,868 bytes, 37.29 seconds, SHA-256 `ef29300b13afd99c0a6c75cca767fd524481cc9226591ea089303255cd42bf9a`.
  - `/tmp/plushpal-cleaned-refs/Sheru-cleaned.wav`, 1,785,772 bytes, 37.20 seconds, SHA-256 `816966e90fdc946094fa889a881230e9458ac8a00568365807f545e202e39aae`.
- Full Mac local-host E2E passed with a fresh profile: one-time bootstrap, parent PIN/profile/preferences (`6-8`, `Teddy`, traits, guidance, 1-day retention), `Jenna.m4a`-derived voice enrollment, preview, approval, authenticated WebSocket child turn, local Qwen response, retained history, and approved sample-conditioned synthesis of the response. This verifies the local/private voice pipeline, not production-grade speaker similarity.
- E2E generated response: “Rainbows form because sunlight passes through water droplets in the atmosphere, bending and reflecting the light. This creates a spectrum of colors around the sky.” The approved voice endpoint emitted a 403,356-byte mono 24 kHz 16-bit WAV with SHA-256 `918e063366932d7eb70bbcc4322eb80355771fcfcc3abcc6f9d9b22396c2775c`. The encrypted reference voice file contained no `RIFF` plaintext marker.
- The development Pocket TTS adapter produced valid mono 16-bit 24 kHz WAV output: preview 94,130 bytes with SHA-256 `8571df712fe91534072b0c7e61b8ef9830144177e8917a9467e15ec3961ff72c`; approved speech 108,446 bytes with SHA-256 `7a7d6052a507645d7f4b00fc0b6b1b5bdee81ae7db35dee0eea9168fbdf54564`.
- The enrolled reference was stored as an opaque AES-GCM file with a unique vault key; the ciphertext contained no `RIFF` marker, the SQLCipher header was non-SQLite, and PIN-authorized deletion removed the encrypted voice file and reset enrollment/approval state.
- The local release gate compiles both model smoke examples. The macOS ZIP contains no Pocket TTS/ONNX model files; the development model is excluded from source/distribution because its published materials state non-commercial use.
- Follow-up voice-quality correction: Pocket TTS evidence is pipeline-only. The product Mac voice path now targets a local Chatterbox runtime selected with `PLUSHPAL_VOICE_ENGINE=chatterbox`; voice approval is disabled until a parent has played a preview and accepted the perceptual match.
- Chatterbox local runtime installation succeeded in `.venv-chatterbox` using Python 3.12, `chatterbox-tts 0.1.7`, `torch 2.6.0`, `torchaudio 2.6.0`, and `setuptools 80.10.2` for the Perth watermark compatibility import. The standard engine healthcheck loaded PerthNet successfully.
- Local Chatterbox standard-engine preview WAVs were generated from the real samples for parent listening qualification:
  - `/tmp/plushpal-chatterbox-previews/Buddy-chatterbox-standard.wav`, 668,240 bytes, mono 24 kHz float WAV, 6.96 seconds, SHA-256 `14f25a7627213c41fabff6933100de1d341f40e1663ce37b4a2f6f641cf517f8`.
  - `/tmp/plushpal-chatterbox-previews/Jenna-chatterbox-standard.wav`, 787,280 bytes, mono 24 kHz float WAV, 8.20 seconds, SHA-256 `abf199f02f60116651fd2b01d6293386d846bb9f1c8690fc15f7513f46f7ffbe`.
  - `/tmp/plushpal-chatterbox-previews/Sheru-chatterbox-standard.wav`, 675,920 bytes, mono 24 kHz float WAV, 7.04 seconds, SHA-256 `4fa5b2004326dd010a0a61cf70e5c0cfc67098358889d88209929465e26823d5`.
- The Rust `chatterbox_voice_smoke` example generated `/tmp/plushpal-chatterbox-previews/Buddy-chatterbox-rust-smoke.wav`, 449,360 bytes, mono 24 kHz float WAV, 4.68 seconds, SHA-256 `496b98b56140e86025f3efb75114eeacb4233e030a0b493f697ef84c6ce5643c`, proving the desktop host's Rust voice engine can invoke the local Chatterbox bridge.
- Android/iOS host code now encrypts the complete profile and retained history using Keystore AES-GCM/Keychain and rejects forged age/character scope before mobile generation. Mobile ABI v2 carries approved guidance into the shared Rust safety orchestrator.
- The consolidated local release audit passes Rust, native CMake, Flutter, JavaScript, Swift parsing, credential scanning, linkage, code-signature, and packaging checks. Two consecutive package builds produced the same ZIP hash after archive timestamp normalization.
- The packaged client bundles Roboto locally. A fresh-origin startup produced no new renderer/font CDN warning; the release gate asserts that the bundled font is present.
- Unsigned macOS bundle startup with the exact verified model. The bundle contains its llama dylib and an `@executable_path/../Frameworks` runtime search path.

## Unsigned development artifact

| Artifact | SHA-256 |
|---|---|
| `PlushPal-0.1.0-macos.zip` | `5be372c0f5c087b5b9a3184f7b79bc8d42ee81d6b1056856739ac8351fc0d0b4` |
| `PlushPal.app/Contents/MacOS/PlushPal` | `cf26325fe28b8c8ee2525a28098ea3b9d839caba8cfefebd683559511534eb33` |
| `PlushPal.app/Contents/Frameworks/libplushpal_llama.dylib` | `2c4ec214277b0ed6df6cf274771fe70de48002e5c89af7c1e55d7b644778e416` |

## Gates that cannot be completed on this host

- Android compile/emulator/physical-device tests: Gradle reaches app configuration, then stops because Android SDK/NDK are not installed. Native validator unit-test sources are ready for that toolchain.
- iOS compile/simulator/physical-device tests were blocked on this June 19 run because only Command Line Tools were active. Superseded on June 24, 2026: full Xcode 26.5 and CocoaPods 1.16.2 are installed, `make ios-simulator` passes, the simulator app launches, and `make ios-device` builds an unsigned device app. Physical iPhone installation still requires Apple signing/provisioning.
- Windows compilation, installer launch, Credential Manager, and hardware tests require a Windows runner.
- macOS distribution signing/notarization requires the owner's Apple Developer identity and credentials.
- Store declarations, privacy labels, and submission require the owner's Apple/Google accounts and final product/legal decisions.
- Cloud provider and Brave live qualification require parent-owned test credentials, signed eligibility metadata, provider retention/region approval, and network-capture evidence. They remain fail-closed in the UI.
- Production voice distribution remains blocked on listening qualification of the local Chatterbox path against real Buddy/Jenna/Sheru samples, objective speaker-similarity scoring, and mobile engine selection. Pocket TTS is development-only, is not bundled, and is not qualified as production-grade voice cloning. In-app recording UX, mobile cloned-voice storage/runtime, accessibility review, safety red-team review, and the supported-device thermal/memory matrix remain product/release work.

## Reproduction

```sh
make check
cargo run --release -p plushpal-desktop-host --example model_smoke \
  --features native-runtime -- /absolute/path/to/qwen3-1.7b-q8-1.gguf
cargo run --release -p plushpal-desktop-host --example voice_smoke \
  --features native-runtime -- \
  /absolute/path/to/license-reviewed-pocket-tts /absolute/path/to/reference.wav /tmp/voice.wav
make package-macos
```
