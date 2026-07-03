# Requirements-to-evidence traceability

Last updated: 2026-07-02

This table tracks current public evidence plus the vNext PlushBuddy Hub target.

| Requirement | Target implementation | Current evidence | Remaining work |
|---|---|---|---|
| Local private backend | PlushBuddy Hub owns APIs, SQLCipher storage, reasoning orchestration, STT fallback, LuxTTS, and pairing | Current Rust Axum host, SQLCipher voice store, Mac launcher, packaged smoke tests | Migrate client-owned profile/history/provider state into Hub |
| Two runtime modes | Privacy local-first and cloud LLM modes only | Runtime-mode plumbing and demo banner exist | Add setup UX, local LLM runtime, Hub provider orchestration |
| Local-first voice input | Verified on-device STT first; Hub local STT fallback; no silent cloud STT | Android/iOS platform STT code exists | Enforce local-only APIs, add Hub STT fallback, add failure UX |
| Local LLM option | `llama.cpp` + recommended GGUF model by Hub memory | Legacy llama.cpp/Qwen paths and model lifecycle crates exist | Productize local LLM mode, model recommendation, safety tests |
| Cloud LLM option | Hub calls Gemini/OpenAI with redacted/minimized prompt | Gemini/OpenAI paths exist in current clients and smoke tests | Move provider calls into Hub, store provider keys in Hub secure storage |
| Toy voice cloning/TTS | LuxTTS worker, approved voice profiles, encrypted processed references | LuxTTS Sheru/Jenna/Buddy enrollment/approval/synthesis E2E passed | Objective speaker-similarity checks and more release-candidate listening evidence |
| Encrypted durable storage | Hub SQLCipher database plus encrypted voice files; clients store only pairing identity | SQLCipher tests, wrong-key/plaintext scans, voice metadata/delete-all tests | Consolidate app state into Hub DB; add backup/export/import |
| Stable client identity | Pair by QR, bind stable `client_id` and device credential, do not rely on IP | Bootstrap/session pairing exists | Add paired-client table, device revocation UI, client key-pair flow |
| Local-only browser | Browser is same-machine Hub UI only | Station-served browser render smoke passed | Remove durable browser state and route browser through Hub APIs |
| Android/iPhone/Mac clients | Thin UI clients for mic, local STT, playback, Hub APIs | Android device launch/pairing passed; iPhone simulator launch passed; Mac client packaged smoke passed | Thin-client migration and physical iPhone QA |
| Public release hygiene | No secrets/private samples/artifacts in repo; artifacts outside checkout | `make public-repo-check`, release bundle checks, GitHub prerelease | Signed/notarized/store-ready artifacts |
