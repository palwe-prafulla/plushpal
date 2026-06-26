# Privacy and security model

Last updated: 2026-06-26

PlushBuddy is designed as a local-first prototype for child pretend play. It is
not a hosted service. The parent runs the app stack locally and provides any
cloud LLM keys they choose to use.

## Core privacy boundary

The product intentionally separates **reasoning** from **voice**:

- Android, iPhone, browser, and Mac clients own kid profiles, character
  profiles, conversation history, provider API keys, and prompt construction.
- PlushBuddy Station owns local voice-profile creation and local text-to-speech.
- Cloud LLM providers receive only the minimized/redacted conversation prompt
  from the active client.
- Raw voice samples are sent only to the local Station for voice-profile
  creation. They are not sent to Gemini/OpenAI by PlushBuddy.

## Data flow summary

| Data | Stored where | Sent to MacStation | Sent to LLM provider |
|---|---|---:|---:|
| Kid name/birthdate/photo | Client local storage | No | No; prompt uses pseudonym/age |
| Character name/persona/photo | Client local storage | Character alias/profile reference only | Persona/prompt fields as needed |
| Parent API key | Client secure storage where available | No | Used directly by active client |
| Raw voice sample | Client during upload; Station during processing | Yes, local network/session only | No |
| Processed voice profile/reference | Station local storage | N/A | No |
| Child utterance | Client conversation state/history | No, except generated response text for TTS | Yes, after redaction/minimization |
| LLM response text | Client history/display | Yes, for voice synthesis | Returned by provider |
| Generated WAV | Station transient output and client playback | N/A | No |

## Secrets and storage

Platform-specific secure storage is used where implemented:

- Android: Android Keystore-backed storage for sensitive client state.
- iPhone: iOS Keychain-backed storage for sensitive client state.
- macOS: Keychain/encrypted local storage paths for Station-managed secrets.
- Browser: parent/kid/character/history data uses browser local storage; provider
  API keys are session-only and are not persisted to local storage. Production
  browser encrypted-state storage remains a future hardening item.

The public repository must not contain:

- provider API keys;
- GitHub tokens;
- private voice samples;
- generated voice profiles;
- local test artifacts;
- model weights or large runtime caches.

Public build/test scripts write generated outputs under:

```text
~/Downloads/PlushPal
```

## Child-safety guardrails

The client prompt construction includes:

- current child age derived from birthdate;
- toy-character persona and persona age;
- parent guidance;
- instruction to avoid asking for personal identifying information;
- instruction to redirect unsafe, secretive, medical, violent, self-harm, or
  adult topics to a trusted grown-up;
- structured response shape where the provider can indicate that a trusted adult
  should be involved.

Guardrails are not treated as a perfect safety boundary. A production release
would need a larger adversarial safety test corpus, provider qualification, and
parent-visible safety controls.

## Threat model

| Threat | Mitigation today | Future hardening |
|---|---|---|
| API key accidentally committed | `.gitignore`, public-repo check, CI hygiene check | pre-commit hook, GitHub secret scanning alerts |
| Raw voice sample leaked to repo | sample folders ignored; docs point to private external folder | automated file-size/media scans |
| External device talks to Station without pairing | bootstrap/session token, host/origin checks, QR pairing for mobile | mDNS pairing, pair-code confirmation, device revocation UI |
| Cloud prompt contains kid PII | pseudonymization/redaction path in client | stronger PII detector and tests |
| Browser state exposed on shared computer | provider API key is session-only; other browser profile/history state is localStorage | browser-side encryption and explicit lock timeout |
| Voice model runtime crashes | Station health/status and retry path | supervisor restart policy and structured diagnostics |
| Unwanted public contributions | PR template + auto-close workflow + disabled repo features | archive repo if fully read-only is desired |

## Logging policy

Product and QA logs should not contain:

- raw provider API keys;
- raw GitHub tokens;
- full prompt payloads containing child text;
- raw audio bytes;
- private local sample paths beyond developer-owned QA traces.

When adding diagnostics, prefer structured status/error codes over content logs.

## Production-readiness checklist

Before a consumer release, PlushBuddy should add:

- signed and notarized macOS apps;
- signed mobile release builds;
- browser local-state encryption;
- stronger child-safety regression suite;
- physical-device iPhone QA;
- Station device revocation UI;
- clearer parent consent UX;
- telemetry/diagnostics that do not collect child content;
- dependency/model checksum verification;
- model-runtime retry/resume logic.
