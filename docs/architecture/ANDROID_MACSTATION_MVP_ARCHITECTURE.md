# PlushBuddy Hub MVP architecture transition

Last updated: 2026-07-02

This document explains how the current Android + Hub/MacStation MVP should evolve
into the **PlushBuddy Hub** architecture.

For the canonical target design, see [`SYSTEM_DESIGN.md`](SYSTEM_DESIGN.md).
For code locations, see [`CODEBASE_DIRECTORY_GUIDE.md`](CODEBASE_DIRECTORY_GUIDE.md).

## 1. Naming

The public product name should move from **MacStation** to **PlushBuddy Hub**.

Implementation names can migrate gradually:

| Old term | New product term |
|---|---|
| MacStation | PlushBuddy Hub |
| MacStation host | Hub backend |
| Station app | Hub launcher |
| Station pairing | Hub pairing |

The first Hub platform is macOS. Later platforms are Windows and Linux.

## 2. Architecture shift

Current prerelease behavior:

- Android/iPhone/browser/Mac clients own some parent/kid/character/history
  state.
- Some clients call Gemini/OpenAI directly.
- MacStation primarily owns voice enrollment and LuxTTS synthesis.

Target Hub behavior:

- Hub owns all durable family state.
- Hub owns business logic, guardrails, redaction, provider calls, and model
  orchestration.
- Clients become UI shells with mic capture, local STT when verified, playback,
  and Hub pairing/session state.

```text
Current:
  Client storage + client reasoning + Station voice

Target:
  Thin clients + Hub backend/storage/reasoning/voice
```

## 3. Supported MVP surfaces

| Surface | Target role |
|---|---|
| Android app | External native voice-first client |
| iPhone app | External native voice-first client |
| Mac app | Native voice-first client, local or external |
| Local browser | Same-machine browser UI only |
| PlushBuddy Hub for macOS | First backend/runtime host |

Remote browser clients are intentionally not supported for now. If a user wants
to connect from another device, they should use a native app.

## 4. Two setup modes

The Hub setup UX should expose exactly two runtime modes.

### 4.1 Privacy local-first

Local pipeline:

```text
client on-device STT when verified
or Hub local STT fallback
-> Hub local LLM
-> Hub LuxTTS
-> client playback
```

Pros:

- maximum privacy;
- no LLM API key;
- no cloud reasoning dependency;
- text and audio stay local after model setup.

Cons:

- larger downloads;
- higher memory requirements;
- local model quality may be lower than Gemini/OpenAI;
- local model knowledge may be stale.

### 4.2 Cloud LLM

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
| Hub STT fallback | `whisper.cpp` + Whisper model, model tier by memory |
| Local LLM | `llama.cpp` + GGUF model, model tier by memory |
| Cloud LLM | Gemini/OpenAI from Hub only |
| Storage | SQLCipher in Hub |

Suggested local model tiers are documented in [`SYSTEM_DESIGN.md`](SYSTEM_DESIGN.md).

## 6. STT policy

Native apps should not silently use cloud speech recognition.

Required behavior:

- Android: use `createOnDeviceSpeechRecognizer` only when available.
- iPhone/Mac: set `requiresOnDeviceRecognition = true` and require
  `supportsOnDeviceRecognition`.
- Windows future: use only verified device/in-process speech recognition.
- If verified on-device STT is unavailable, send bounded audio to Hub local STT.
- If Hub STT is unavailable, voice input is unavailable and typing is fallback.

## 7. Hub database ownership

The Hub owns one encrypted SQLCipher database per Hub installation.

Target database:

```text
~/Library/Application Support/PlushPal/plushbuddy-hub.sqlcipher
```

The Hub DB owns:

- parent settings;
- runtime mode;
- provider keys or secure references;
- kids;
- characters;
- character photos;
- voice profile metadata;
- encrypted voice reference pointers;
- conversation sessions;
- conversation turns;
- paired clients;
- audit events.

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
authorization are enforced by the Hub.

## 10. Migration plan

1. Add Hub-backed kids/characters/history/provider APIs.
2. Update Flutter client to use Hub APIs for local browser/Mac first.
3. Move cloud reasoning from client native bridges into Hub.
4. Add runtime-mode setup with privacy local-first and cloud LLM choices.
5. Add stable client identity and device revocation.
6. Migrate Android/iPhone clients to thin-client mode.
7. Enforce verified local STT before transcript submission.
8. Add Hub STT fallback.
9. Add local LLM runtime and model recommendation.
10. Rename user-facing MacStation strings to PlushBuddy Hub.

## 11. Current compatibility note

Until the migration is complete, some code/docs/tests may still use MacStation
or client-owned storage terminology. Those are implementation details from the
current prerelease, not the target architecture.
