# ToyTalk Hub MVP architecture

Last updated: 2026-07-05

This document explains the Android/iPhone/Mac/browser + Hub implementation and
the current **ToyTalk Hub** product architecture. Some implementation paths
still use the historical `macstation` name, but the product architecture and
user-facing name are ToyTalk Hub.

For the canonical design, see [`SYSTEM_DESIGN.md`](SYSTEM_DESIGN.md).
For code locations, see [`CODEBASE_DIRECTORY_GUIDE.md`](CODEBASE_DIRECTORY_GUIDE.md).

## 1. Naming

The public product name is **ToyTalk Hub**.

Some files and automation scripts still contain the historical `macstation`
path/name because that was the original internal implementation label. Treat
those as legacy code-path names only. Product docs, UI, and user-facing flows
should say **ToyTalk Hub**.

The first Hub platform is macOS. Later platforms are Windows and Linux.

## 2. Architecture shift

Implemented Hub behavior:

- Hub owns durable family state in SQLCipher.
- Hub has a first-party `hub-*` scoped store for parent PIN, Cloud AI keys,
  active provider, paired-device registry, and revocation.
- Hub owns business logic, guardrails, redaction, provider calls, and model
  orchestration.
- Hub owns voice enrollment, voice approval, and LuxTTS synthesis.
- Paired clients are UI shells with mic capture, local STT when verified,
  playback, stable client identity, and Hub pairing/session state.
- Pairing/bootstrap returns the Hub's stable `hub-*` identity in
  `X-PlushBuddy-Hub-Id`; clients persist it with their pairing credentials.
- Every private persisted API call includes both `X-PlushBuddy-Client-Id` and
  `X-PlushBuddy-Hub-Id`. Client-owned APIs resolve the target encrypted store
  from the client ID. Hub-owned APIs, including parent PIN checks and Cloud AI
  model settings, validate the Hub ID and open the Hub-scoped encrypted store
  rather than relying on IP address, LAN URL, or an implicit root fallback.
- Revoked paired clients are rejected on authenticated requests as well as on
  future bootstrap/pairing attempts.

```text
Current Hub-backed product path:
  Thin clients + Hub backend/storage/reasoning/voice
```

## 3. Supported MVP surfaces

| Surface | Target role |
|---|---|
| Android app | External native voice-first client |
| iPhone app | External native voice-first client |
| Embedded Mac experience | Native voice-first client inside ToyTalk Hub |
| Local browser | Same-machine browser UI only |
| ToyTalk Hub for macOS | First backend/runtime host |

Remote browser clients are intentionally not supported for now. If a user wants
to connect from another device, they should use a native app.

## 4. Two setup modes

The Hub setup UX should expose exactly two runtime modes.

### 4.1 Local AI

Local pipeline:

```text
client on-device STT when verified
or Hub local STT fallback
-> Hub local AI model
-> Hub LuxTTS
-> client playback
```

Pros:

- maximum privacy;
- no AI API key;
- no cloud reasoning dependency;
- text and audio stay local after model setup.

Cons:

- larger downloads;
- higher memory requirements;
- local model quality may be lower than Gemini/OpenAI;
- local model knowledge may be stale.

### 4.2 Cloud AI

Hybrid pipeline:

```text
client on-device STT when verified
or Hub local STT fallback
-> Hub redaction/guardrails
-> Gemini/OpenAI
-> Hub LuxTTS
-> client playback
```

Pros:

- better answer quality;
- lower local compute requirements;
- parent can use their own Gemini/OpenAI key.

Cons:

- redacted text leaves the local network;
- requires parent consent/API key;
- provider availability, pricing, latency, and behavior can change.

## 5. Model/runtime stack

| Capability | Target implementation |
|---|---|
| Voice cloning/TTS | LuxTTS |
| Hub STT fallback | Lazy Hub setup using the Hub-managed Python/Transformers runtime for `openai/whisper-base`; `whisper.cpp` remains the future lean-runtime target |
| Local AI model | `llama.cpp` + GGUF model, model tier by memory |
| Cloud AI | Gemini/OpenAI from Hub only |
| Storage | SQLCipher in Hub |

Suggested local model tiers are documented in [`SYSTEM_DESIGN.md`](SYSTEM_DESIGN.md).

## 6. STT policy

Native apps should not silently use cloud speech recognition.

Required behavior:

- Android: use `createOnDeviceSpeechRecognizer` only when available.
- iPhone/Mac: set `requiresOnDeviceRecognition = true` and require
  `supportsOnDeviceRecognition`.
- Windows future: use only verified device/in-process speech recognition.
- If verified Android/iPhone on-device STT is unavailable or fails, record a
  bounded local WAV and send it to Hub local STT.
- If Hub STT is unavailable, voice input is unavailable and typing is fallback.

## 7. Hub database ownership

The Hub owns encrypted SQLCipher storage. A root Hub database stores pairing,
revocation, runtime registry, migrations, and Hub-level metadata. Stable paired
clients get isolated encrypted scoped stores for family data.

Target database:

```text
~/Library/Application Support/ToyTalk/toytalk-hub.sqlcipher
```

The root DB is retained for compatibility/key derivation. The Hub has a stable
`hub-*` scoped store that owns:

- parent PIN / parent gate profile;
- runtime mode;
- paired clients;
- paired-client revocation;
- Cloud AI provider keys and active provider;
- audit events;
- schema migrations.

Each per-client store owns:

- parent settings;
- kids;
- characters;
- character photos;
- voice profile metadata;
- encrypted voice reference pointers;
- conversation sessions;
- conversation turns;

External clients should not create separate durable profile/history databases.
They store only Hub pairing/session credentials.

## 8. Stable client identity

The Hub must not identify clients by IP address.

Each native client generates:

- stable `client_id`;
- device key pair or high-entropy device secret;
- friendly device label.

During QR pairing, the Hub binds that identity to the family Hub:

```text
paired_clients
  client_id
  platform
  device_label
  public_key_or_secret_ref
  created_at
  last_seen_at
  last_seen_ip
  revoked_at
```

Changing IP address should not create a new profile or lose data. IP is
diagnostic only.

## 9. Hub API groups

Target API groups:

```text
/api/v1/pairing/*
/api/v1/session/*
/api/v1/setup/*
/api/v1/kids/*
/api/v1/characters/*
/api/v1/voice/*
/api/v1/conversations/*
/api/v1/runtime/*
/api/v1/provider/*
/api/v1/diagnostics/*
```

The clients call these APIs for every durable action. Parent PIN and session
authorization are enforced by the Hub; clients do not create or store a separate
parent PIN in paired product usage.

## 10. Remaining hardening plan

1. Broaden Mac/WebKit microphone QA for the implemented Hub STT fallback.
2. Broaden local/cloud reasoning safety and quality regression coverage.
3. Polish the two-choice runtime setup screen and latency diagnostics.
4. Rename remaining historical `macstation` strings/paths to ToyTalk Hub
   where practical.

## 11. Current compatibility note

Some code/tests still use `macstation` as an implementation path name. That is
legacy naming; the product architecture is ToyTalk Hub.
