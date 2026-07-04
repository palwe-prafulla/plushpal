# Requirements-to-evidence traceability

Last updated: 2026-07-03

This table tracks current public evidence plus the vNext PlushBuddy Hub target.

| Requirement | Target implementation | Current evidence | Remaining work |
|---|---|---|---|
| Local private backend | PlushBuddy Hub owns APIs, SQLCipher storage, reasoning orchestration, STT fallback hook, LuxTTS, pairing, and encrypted backup/restore | Current Rust Axum host, SQLCipher voice store, Mac launcher, packaged smoke tests, Hub-backed clients, packaged Station app, parent-PIN encrypted backup/import API and client bridge tests, per-client scoped-store regression test | Broaden release-device QA |
| Two runtime modes | Privacy local-first and cloud LLM modes only | Runtime-mode plumbing, Station runtime-mode selector, demo/runtime banner, Gemini/OpenAI Hub paths exist | Productized local LLM runtime and first-run setup polish |
| Local-first voice input | Verified on-device STT first; Hub local STT fallback; no silent cloud STT | Android/iOS enforce on-device recognition and can record bounded fallback WAV clips for Hub STT; local browser/Mac WebKit can record bounded WAV clips for Hub STT; Hub `/api/v1/stt/transcribe` is authenticated; packaged Station includes and health-checks `openai/whisper-base` wrapper | Broaden Mac/WebKit microphone QA and replace Python STT wrapper with lean runtime if needed |
| Local LLM option | `llama.cpp` + recommended GGUF model by Hub memory | Legacy llama.cpp/Qwen paths and model lifecycle crates exist | Productize local LLM mode, model recommendation, safety tests |
| Cloud LLM option | Hub calls Gemini/OpenAI with redacted/minimized prompt | Gemini/OpenAI Hub paths and encrypted provider-key storage exist | Broaden safety/eval coverage and setup UX |
| Toy voice cloning/TTS | LuxTTS worker, approved voice profiles, encrypted processed references | LuxTTS Sheru/Jenna/Buddy enrollment/approval/synthesis E2E passed | Objective speaker-similarity checks and more release-candidate listening evidence |
| Encrypted durable storage | Hub root SQLCipher registry plus per-client encrypted SQLCipher stores and encrypted voice files; clients store only pairing identity; backup export is parent-PIN encrypted | SQLCipher tests, wrong-key/plaintext scans, voice metadata/delete-all tests, paired-client registry tests, per-client isolation regression test, native backup wrong-PIN/import test, HTTP backup gate test, browser/mobile bridge tests | Add stronger client key-pair credential flow |
| Stable client identity | Pair by QR, bind stable `client_id`, do not rely on IP, allow parent revocation | Bootstrap/session pairing, paired-client table, revocation API/UI tests | Add stronger client key-pair credential flow |
| Local-only browser | Browser is same-machine Hub UI only | Station-served browser render smoke passed; browser backend uses Hub APIs | Continue browser UX polish |
| Android/iPhone/Mac clients | Thin UI clients for mic, local STT/fallback capture, playback, Hub APIs | Android device launch/pairing passed; Android APK builds; iPhone simulator build passes; Mac client packaged smoke passed; browser backend STT adapter test covers Hub fallback request shape | Physical iPhone QA and broader Mac microphone QA |
| Public release hygiene | No secrets/private samples/artifacts in repo; artifacts outside checkout | `make public-repo-check`, release bundle checks, GitHub prerelease | Signed/notarized/store-ready artifacts |
