# Privacy and security model

Last updated: 2026-07-02

PlushBuddy is designed as a local-first pretend-play system. The current
architecture uses **PlushBuddy Hub** as the local private backend. The Hub runs
on the parent’s computer, stores durable app data in an encrypted SQLCipher
database, runs voice generation locally, and exposes paired APIs to native
clients on the same local network.

## Core privacy boundary

Current paired-product architecture:

- Hub owns kid profiles, character profiles, provider settings, conversation
  history, prompt construction, runtime mode, and voice profiles.
- Android/iPhone/Mac/future Windows clients are thin UI clients.
- Local browser is supported only on the same machine as the Hub.
- Remote browser clients are not supported for now.
- Raw voice samples are sent only to the Hub over the paired local session for
  voice-profile creation.
- Cloud LLM providers never receive raw audio or voice samples.

## Runtime modes

| Mode | Cloud use | Local processing |
|---|---|---|
| Privacy local-first | No cloud LLM calls after model setup/update checks | Packaged Hub local STT fallback, local LLM target, LuxTTS, SQLCipher |
| Cloud LLM | Redacted/minimized text prompt goes to Gemini/OpenAI | Redaction, guardrails, LuxTTS, SQLCipher |

Provider cloud STT is not used silently. If cloud STT is ever added, it must be
an explicit parent opt-in.

## Speech privacy

Native clients must prefer verified on-device STT:

- Android: on-device `SpeechRecognizer` only when available.
- iPhone/Mac: Apple speech recognition with `requiresOnDeviceRecognition`.
- Windows future: verified device/in-process recognizer only.

If verified on-device STT is unavailable or fails, Android/iPhone record a
bounded local WAV and send it to Hub local STT over the local paired session.
Local browser/Mac WebKit clients use the same bounded-audio policy when browser
microphone capture is available. The Hub packages and health-checks a local
Whisper wrapper for this endpoint.

## Data flow summary

| Data | Stored where | Sent to Hub | Sent to cloud LLM |
|---|---|---:|---:|
| Kid name/birthdate/photo | Hub SQLCipher | Native clients read/write via authenticated API | No; prompt uses age/pseudonym |
| Character/persona/photo | Hub SQLCipher | Native clients read/write via authenticated API | Redacted/persona fields only when needed |
| Parent provider API key | Hub secure storage / SQLCipher secret reference | Entered through Hub/client setup API | Used by Hub in cloud LLM mode |
| Raw voice sample | Hub transient processing input | Yes, local paired session only | No |
| Processed voice reference | Hub encrypted voice store | N/A | No |
| Child utterance audio | Client temporary or Hub STT fallback | Only if Hub STT fallback is needed | No |
| Transcript text | Hub conversation pipeline | Yes | Local mode: no; cloud mode: redacted/minimized prompt |
| LLM response text | Hub SQLCipher/history | Returned to client for display/playback | Returned by provider in cloud mode |
| Generated WAV | Hub transient output and client playback | N/A | No |

## Secrets and storage

Hub storage:

- SQLCipher database for durable app records.
- Platform secure storage for DB key wrapping and high-value secrets where
  practical.
- Encrypted voice reference files referenced by SQLCipher.
- Paired-client credentials stored in Hub DB/secure storage.

Paired client storage:

- stable client ID;
- pairing/session secret;
- Hub URL / last-known Hub address;
- short-lived session token/cookie;
- no durable kids, characters, API keys, or conversation history.

## Paired-client identity

IP address is never identity. Clients generate a stable identity at first
pairing and send it with Hub requests. Hub stores a paired-device registry with
`client_id`, platform, friendly label, creation time, last seen time, last seen
IP for diagnostics only, and parent-gated revocation. Normal family-data APIs
resolve to an encrypted per-client Hub store using that stable `client_id`.

If a phone’s IP changes, it remains the same paired client.

## Threat model

| Threat | Mitigation target |
|---|---|
| Raw voice sample leaks to cloud | Hub sends only text to cloud LLM; raw audio stays local |
| Cloud prompt contains child PII | Hub redaction/pseudonymization before provider call |
| Client IP changes causing duplicated state | Stable client identity independent of IP |
| Unpaired device talks to Hub | QR bootstrap, authenticated sessions, device revocation |
| API key appears in logs/UI | Key never returned to clients; diagnostics redact secrets |
| Browser storage exposes data | Browser is local-only and durable state lives in Hub |
| Host sleeps during play | Hub launcher should hold a no-system-sleep assertion while active |

## Logging policy

Product and QA logs should not contain:

- raw provider API keys;
- raw GitHub tokens;
- full prompts containing child text;
- raw audio bytes;
- private local sample paths beyond developer-owned QA traces;
- SQLCipher keys or session secrets.

Prefer structured status/error codes over content logs.

## Production-readiness checklist

Before a consumer release, PlushBuddy should add:

- signed and notarized Hub launcher;
- signed Android/iPhone/Mac clients;
- stronger paired-client key-pair credentials beyond bearer session cookies;
- file-based backup/export/import UX polish beyond the current parent-PIN
  encrypted clipboard flow;
- broaden Mac/WebKit microphone QA across macOS versions;
- replace the Python/Transformers Hub STT wrapper with a leaner packaged
  `whisper.cpp` runtime if performance requires it;
- local LLM bakeoff and safety regression suite;
- clear parent consent for cloud LLM mode;
- telemetry/diagnostics that do not collect child content;
- dependency/model checksum verification and runtime recovery.
