# Private Voice Plush Toy App — Architecture & Design Specification

## 1. Purpose

This document defines the professional architecture, design, security boundaries, and execution flow for a private, non-commercial, cross-platform voice plush toy application.

The app is intended for personal family use. A child can speak to a plush character through an Android or macOS app, and the character responds in a playful, age-appropriate voice.

The design prioritizes:

- Cross-platform support for Android and macOS.
- No vendor API keys in the frontend app.
- Backend-mediated AI provider access.
- Local-first child profile and memory.
- Local LuxTTS voice generation for the current MVP, because manual provider bakeoffs showed better voice/vibe preservation than cloud instant cloning.
- Minimal cloud data exposure.
- Strong safety guardrails.
- Low-cost AI provider usage.
- Easy provider replacement in the future.

---

## 2. High-Level Architecture

### 2.1 Current MVP Architecture Update

The current MVP should use a **Mac Station + Android/browser client** architecture:

- The macOS app is a setup and service supervisor, not the primary child UI.
- The macOS app installs/verifies/reuses local runtime assets in `~/Library/Application Support/PlushPal`.
- The macOS app starts local services and shows health for each required service.
- The browser UI is the first stable parent/child UI on Mac.
- Android pairs to the Mac Station through a QR/link flow and uses the Mac-hosted local services. Station now generates a one-time LAN bootstrap URL and the host accepts only the exact Station-detected LAN host/origin in addition to loopback. Android still needs the QR scanner/session-exchange UI.
- LuxTTS runs locally on the Mac Station for character voice generation.
- Gemini/OpenAI can be used for parent-consented STT/reasoning once provider keys and consent are configured.
- Closing the macOS app stops running services but does not delete downloaded models, virtual environments, caches, encrypted profiles, or voice samples.

The embedded macOS WebView remains optional. It should only become a primary launch path after the browser flow is stable.

```text
+--------------------------------------------------+
|              PlushPal Station.app (macOS)         |
|--------------------------------------------------|
| - Native setup/progress UI                        |
| - User-scoped install/cache directories           |
| - Starts/stops local PlushPal services            |
| - Health checks: storage, reasoning, voice, host  |
| - Shows browser launch and LAN pairing link       |
+-------------------------+------------------------+
                          |
                          | loopback / local network pairing
                          v
+--------------------------------------------------+
|              Local PlushPal Host (Mac)            |
|--------------------------------------------------|
| - Parent profile and encrypted local storage      |
| - Character/voice enrollment APIs                 |
| - Browser UI assets                               |
| - Optional Gemini/OpenAI reasoning gateway        |
| - Local LuxTTS voice service adapter              |
+-------------------------+------------------------+
              |                              |
              | local process/service         | parent-consented HTTPS
              v                              v
+-------------------------+        +-------------------------+
| Local LuxTTS Runtime    |        | Gemini/OpenAI APIs       |
| - Voice preview/speech  |        | - STT/reasoning optional |
| - Best current voice fit|        | - No voice cloning MVP   |
+-------------------------+        +-------------------------+
              ^
              |
+-------------+------------------------------------+
| Android App / Browser UI                         |
| - Child-facing push-to-talk UI                   |
| - Character selection                            |
| - Audio capture/playback                         |
| - Pairs to Mac Station for local services        |
+--------------------------------------------------+
```

```text
+--------------------------------------------------+
|                  Flutter Client                  |
|              Android App / macOS App             |
|--------------------------------------------------|
| - Push-to-talk UI                                |
| - Local audio recording                          |
| - Local safety pre-check                         |
| - Character selection                            |
| - Local child profile                            |
| - Local-only memory                              |
| - Secure storage for backend device token        |
| - Audio playback                                 |
+-------------------------+------------------------+
                          |
                          | HTTPS
                          | Device token / session token
                          v
+--------------------------------------------------+
|                Private Backend AI Gateway        |
|--------------------------------------------------|
| - Device authentication                          |
| - Request validation                             |
| - Rate limiting                                  |
| - Prompt assembly                                |
| - Safety classification                          |
| - STT provider adapter                           |
| - Reasoning provider adapter                     |
| - TTS provider adapter                           |
| - Response validation                            |
| - Sanitized observability                        |
| - Provider secret management                     |
+------------------+-------------------+-----------+
                   |                   |
                   |                   |
          +--------v--------+  +-------v--------+
          |  Gemini API     |  | ElevenLabs API |
          |-----------------|  |----------------|
          | - STT           |  | - TTS          |
          | - Reasoning     |  | - Voice profile|
          +-----------------+  +----------------+
```

---

## 3. Core Design Principle

The frontend app is never allowed to directly call Gemini, ElevenLabs, OpenAI, or any other paid AI provider.

The frontend only calls the private backend AI Gateway.

### Why

This prevents:

- API key leakage from Android APKs or macOS app bundles.
- Unauthorized use of paid provider accounts.
- Prompt bypass through modified clients.
- Unlimited usage from compromised clients.
- Provider lock-in inside the mobile/desktop app.
- Billing surprises.

---

## 4. Target Platforms

### 4.1 Frontend Platforms

| Platform | Role |
|---|---|
| Android | Primary child-facing app |
| macOS | Development, testing, parent/admin use, optional child-facing desktop app |

### 4.2 Recommended Frontend Framework

Use **Flutter**.

Flutter is recommended because:

- Single codebase for Android and macOS.
- Mature UI framework.
- Strong plugin ecosystem for audio, storage, networking, and permissions.
- Fast iteration.
- Good fit for a private MVP and later polish.

---

## 5. System Components

## 5.1 Flutter Client

### Responsibilities

The Flutter client handles:

- Push-to-talk interaction.
- Microphone permission.
- Audio recording.
- Optional local voice activity detection.
- Local child safety keyword pre-check.
- Character selection.
- Local child profile.
- Local memory facts.
- Local conversation display, if enabled.
- Secure storage of backend device/session token.
- Playback of returned audio.
- Friendly fallback UX.

### Non-Responsibilities

The Flutter client must not contain:

- Gemini API key.
- ElevenLabs API key.
- OpenAI API key.
- Provider voice IDs if they are sensitive.
- Full final prompt assembly logic.
- Billing-sensitive retry behavior.
- Final safety enforcement.
- Admin secrets.

---

## 5.2 Backend AI Gateway

The backend is the trusted control plane for all AI calls.

### Responsibilities

The backend handles:

- Device authentication.
- Session validation.
- Request size validation.
- Rate limiting.
- Audio duration limits.
- STT provider calls.
- Transcript safety classification.
- Prompt construction.
- Reasoning provider calls.
- LLM response validation.
- TTS provider calls.
- Voice alias mapping.
- Cost controls.
- Sanitized logs.
- Secret management.
- Provider abstraction.

### Recommended Backend Stack

For fastest MVP:

```text
FastAPI + Python
```

Alternative options:

| Stack | Fit |
|---|---|
| FastAPI / Python | Fastest AI integration and prototyping |
| Node.js / TypeScript | Strong async and streaming support |
| Spring Boot / Java | Familiar enterprise-grade backend, slower MVP |

Recommended for this project:

```text
FastAPI + Python + Docker
```

---

## 5.3 AI Providers

### Initial Low-Cost Provider Setup

| Capability | Provider |
|---|---|
| Speech-to-text | Gemini API or local/browser capture path |
| Reasoning / conversation | Gemini Flash/Flash-Lite or local model |
| Text-to-speech | Local LuxTTS on Mac Station |
| Voice profile | Encrypted local sample/profile consumed by LuxTTS |
| Safety fallback | Local app audio or backend fixed response |

ElevenLabs and other cloud voice-cloning providers remain replaceable future adapters, but they are not the current MVP voice path because manual tests did not preserve the target child-created toy voice as well as local LuxTTS.

### Provider Abstraction

Backend code should avoid hardcoding provider logic into business flow.

Use interfaces:

```text
SpeechToTextProvider
  - GeminiSpeechProvider
  - FutureOpenAISpeechProvider
  - FutureLocalWhisperProvider

ReasoningProvider
  - GeminiReasoningProvider
  - FutureOpenAIReasoningProvider
  - FutureLocalModelProvider

TextToSpeechProvider
  - ElevenLabsTtsProvider
  - FutureOpenAITtsProvider
  - FutureNativeTtsProvider
```

This allows swapping Gemini or ElevenLabs later without changing the Flutter app.

---

## 6. End-to-End Conversation Flow

```text
1. Child presses and holds talk button.
2. Flutter records microphone audio.
3. Flutter runs local safety keyword pre-check.
4. Flutter sends audio to backend AI Gateway.
5. Backend authenticates device/session token.
6. Backend validates request limits.
7. Backend sends audio to STT provider.
8. Backend receives transcript.
9. Backend runs transcript safety classification.
10. Backend either:
    a. returns a parent-redirect fallback, or
    b. builds a child-safe prompt.
11. Backend calls reasoning model.
12. Backend validates the generated response.
13. Backend sends final short text to ElevenLabs.
14. ElevenLabs returns audio.
15. Backend returns audio to Flutter.
16. Flutter plays character voice.
17. Flutter optionally stores transcript/response locally.
```

---

## 7. Runtime Sequence Diagram

```text
Child
  |
  | speaks
  v
Flutter App
  |
  | record audio
  | local pre-check
  |
  | POST /v1/conversation/respond
  v
Backend AI Gateway
  |
  | authenticate device
  | validate limits
  |
  | audio -> STT
  v
Gemini STT
  |
  | transcript
  v
Backend AI Gateway
  |
  | safety classify
  | build prompt
  |
  | prompt -> reasoning model
  v
Gemini Reasoning
  |
  | reply text
  v
Backend AI Gateway
  |
  | validate response
  | reply text -> TTS
  v
ElevenLabs
  |
  | MP3/audio bytes
  v
Backend AI Gateway
  |
  | return audio response
  v
Flutter App
  |
  | play audio
  v
Child hears toy reply
```

---

## 8. Frontend Architecture

## 8.1 Flutter Package Structure

```text
voice_plush_app/
  lib/
    main.dart

    app/
      app.dart
      router.dart
      theme.dart

    features/
      talk/
        talk_screen.dart
        talk_controller.dart
        talk_state.dart

      characters/
        character_screen.dart
        character_model.dart
        character_repository.dart

      parent_settings/
        parent_settings_screen.dart
        parent_settings_controller.dart

      history/
        conversation_history_screen.dart
        conversation_log_model.dart

    core/
      api/
        ai_gateway_client.dart
        api_error.dart

      audio/
        audio_recorder.dart
        audio_player.dart
        audio_permission_service.dart

      auth/
        device_token_service.dart
        session_service.dart

      safety/
        local_safety_filter.dart

      storage/
        secure_token_store.dart
        local_profile_store.dart
        local_memory_store.dart
        conversation_log_store.dart

      models/
        child_profile.dart
        toy_character.dart
        conversation_turn.dart
        safety_action.dart

    platform/
      android/
        android_notes.md

      macos/
        macos_notes.md
```

---

## 8.2 Key Flutter Packages

| Need | Package |
|---|---|
| Audio recording | `record` |
| Microphone permissions | `permission_handler` |
| Audio playback | `just_audio` |
| Secure token storage | `flutter_secure_storage` |
| Local database | `sqflite`, `drift`, or SQLCipher later |
| HTTP client | `dio` or `http` |
| State management | Riverpod, Bloc, or Provider |

Recommended:

```text
record
permission_handler
just_audio
flutter_secure_storage
dio
riverpod
```

---

## 8.3 Android Requirements

### Android Permissions

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
```

The app must also request microphone permission at runtime.

---

## 8.4 macOS Requirements

### Entitlements

Add microphone entitlement in:

```text
macos/Runner/DebugProfile.entitlements
macos/Runner/Release.entitlements
```

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Info.plist

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone so your child can talk to the plush character.</string>
```

---

## 9. Backend Architecture

## 9.1 Backend Modules

```text
backend/
  app/
    main.py

    api/
      routes/
        health.py
        session.py
        conversation.py
        characters.py
        safety.py

    core/
      config.py
      secrets.py
      logging.py
      rate_limit.py
      errors.py

    auth/
      device_auth.py
      session_tokens.py

    providers/
      stt/
        base.py
        gemini_stt.py

      reasoning/
        base.py
        gemini_reasoning.py

      tts/
        base.py
        elevenlabs_tts.py

    safety/
      transcript_classifier.py
      response_validator.py
      local_rules.py

    prompts/
      prompt_builder.py
      character_templates.py
      age_policy.py

    models/
      request_models.py
      response_models.py
      domain_models.py

    storage/
      metadata_db.py
      device_repository.py
      usage_repository.py

    observability/
      metrics.py
      audit_logger.py

  Dockerfile
  docker-compose.yml
  requirements.txt
```

---

## 9.2 Backend API Endpoints

### Health

```http
GET /v1/health
```

Response:

```json
{
  "status": "ok"
}
```

---

### Start Session

```http
POST /v1/session/start
```

Request:

```json
{
  "device_id": "home-android-tablet-1",
  "device_secret": "device-secret-created-by-parent"
}
```

Response:

```json
{
  "session_token": "short-lived-session-token",
  "expires_in_seconds": 3600
}
```

---

### Get Characters

```http
GET /v1/characters
```

Response:

```json
{
  "characters": [
    {
      "character_id": "teddy",
      "display_name": "Teddy",
      "description": "A warm, silly bear who loves bedtime stories.",
      "voice_alias": "warm_bear"
    }
  ]
}
```

The real ElevenLabs voice ID is never returned to the client.

---

### Conversation Respond

```http
POST /v1/conversation/respond
```

Request:

```json
{
  "device_id": "home-android-tablet-1",
  "character_id": "teddy",
  "child_profile": {
    "age": 5,
    "vocabulary_tier": "EARLY"
  },
  "local_memory": {
    "favorite_animal": "unicorn",
    "favorite_color": "purple"
  },
  "audio": {
    "format": "wav",
    "sample_rate": 16000,
    "base64": "..."
  }
}
```

Response:

```json
{
  "request_id": "req_123",
  "safety_action": "ALLOW",
  "transcript": "Can you tell me a dinosaur story?",
  "reply_text": "Rex wore tiny shoes and stomped to snack time!",
  "audio": {
    "format": "mp3",
    "base64": "..."
  }
}
```

Safety fallback response:

```json
{
  "request_id": "req_456",
  "safety_action": "REDIRECT_TO_PARENT",
  "transcript": "I feel hurt",
  "reply_text": "That sounds important. Please talk to Mama or Papa right now.",
  "audio": {
    "format": "mp3",
    "base64": "..."
  }
}
```

---

### Safety Event

```http
POST /v1/safety/event
```

Request:

```json
{
  "device_id": "home-android-tablet-1",
  "event_type": "LOCAL_PRECHECK_REDIRECT",
  "character_id": "teddy",
  "timestamp": 1710000000
}
```

---

## 10. Authentication Design

## 10.1 Device Token Model

For personal family use, use a simple parent-provisioned device token.

```text
Parent creates device in backend
Backend generates device_id + device_secret
Parent enters or scans token into app
App stores token securely
App exchanges device_secret for short-lived session token
App uses session token for requests
```

## 10.2 Token Storage

Frontend stores only:

- `device_id`
- `session_token`
- optionally encrypted `device_secret`

Use platform secure storage:

| Platform | Secure Storage |
|---|---|
| Android | Android Keystore-backed secure storage |
| macOS | Keychain-backed secure storage |

---

## 11. Secrets Management

## 11.1 Never Store These in Flutter

- Gemini API key
- ElevenLabs API key
- Provider admin keys
- Database passwords
- Production secrets
- Raw ElevenLabs voice IDs, if sensitive

## 11.2 Backend Secret Storage

Development:

```text
.env file
```

Production:

```text
Cloud Secret Manager
Environment variables injected at runtime
No checked-in secrets
```

## 11.3 Example Backend Environment Variables

```text
APP_ENV: production
Gemini API key: injected by deployment secrets
ElevenLabs API key: injected by deployment secrets
Device-token signing secret: injected by deployment secrets
Database URL: injected by deployment secrets
Redis URL: injected by deployment secrets
MAX_AUDIO_SECONDS: 15
MAX_REQUESTS_PER_HOUR: 30
MAX_REQUESTS_PER_DAY=100
```

---

## 12. Rate Limiting and Cost Controls

## 12.1 Per-Device Limits

Recommended defaults:

| Limit | Value |
|---|---|
| Max audio length | 10–15 seconds |
| Max requests per hour | 30 |
| Max requests per day | 100 |
| Max transcript length | 300 characters |
| Max response length | 30 words |
| Max TTS characters | 300 characters |
| Max retry count | 1 |
| Always-listening mode | Disabled |

## 12.2 Parent-Triggered Modes

| Mode | Max Words |
|---|---|
| Normal answer | 25–30 words |
| Joke mode | 40 words |
| Story mode | 120 words |
| Bedtime story | 250 words |

Story and bedtime modes should be parent-enabled because they can consume more TTS quota.

---

## 13. Child Safety Architecture

The system uses layered safety.

```text
Frontend local pre-check
  ↓
Backend transcript safety classifier
  ↓
Prompt rules
  ↓
LLM response validation
  ↓
TTS
```

---

## 13.1 Frontend Local Pre-Check

The frontend runs a fast local keyword filter before sending to the backend.

Example trigger terms:

```text
hurt
bleeding
can't breathe
scared
unsafe
die
kill
knife
gun
fire
medicine
private parts
secret
don't tell mom
don't tell dad
```

If matched, the frontend may skip the LLM flow and play a local fallback:

```text
That sounds important. Please talk to Mama or Papa right now.
```

For professional behavior, the frontend should also report a sanitized safety event to the backend.

---

## 13.2 Backend Transcript Safety Classifier

After STT, backend classifies the transcript into:

```text
ALLOW
REDIRECT_TO_PARENT
BLOCK
```

### ALLOW

Normal safe child conversation.

### REDIRECT_TO_PARENT

Potentially important, emotional, medical, unsafe, or sensitive issue.

The toy replies:

```text
That sounds important. Please talk to Mama or Papa right now.
```

### BLOCK

Used for malformed, abusive, unsafe, or repeated problematic input.

The toy replies with a neutral fallback or stays silent depending on parent settings.

---

## 13.3 LLM Prompt Safety Rules

The backend owns final prompt construction.

The frontend may send child profile and local memory facts, but the frontend does not send the final system prompt.

Example system policy:

```text
You are Teddy, a kind and silly plush toy speaking to a 5-year-old child.

Rules:
- Reply in 1–2 short sentences.
- Use simple words.
- Maximum 25 words.
- Be warm, playful, and safe.
- Never discuss adult, violent, scary, medical, legal, or unsafe topics.
- Never ask the child to keep secrets.
- Never encourage physical actions that require adult supervision.
- If the child seems hurt, scared, unsafe, or asks about a grown-up topic, say:
"That sounds important. Please talk to Mama or Papa right now."
```

---

## 13.4 Response Validator

Before sending text to TTS, backend validates:

- Max word count.
- No scary terms.
- No unsafe instructions.
- No medical advice.
- No adult topics.
- No secrecy framing.
- No content that bypasses parent involvement.
- No long rambling output.

If validation fails:

```text
Use safe fallback response
Do not send unsafe response to TTS
Log sanitized safety metadata
```

---

## 14. Prompt Construction

## 14.1 Prompt Inputs

Backend prompt builder receives:

- Character ID.
- Child age.
- Vocabulary tier.
- Safe local memory facts.
- Latest transcript.
- Conversation mode.
- Parent settings.
- Safety classification result.

## 14.2 Character Template

Example:

```json
{
  "character_id": "teddy",
  "display_name": "Teddy",
  "style": "warm, gentle, silly",
  "favorite_themes": ["animals", "bedtime", "snacks", "dinosaurs"],
  "max_words": 25,
  "voice_alias": "warm_bear"
}
```

## 14.3 Age Policy

| Age | Vocabulary | Max Words | Style |
|---|---|---:|---|
| 5 and under | Concrete, simple | 15–25 | Comforting, playful |
| 6–8 | Early elementary | 30 | Curious, creative |
| 9+ | Friendly, clear | 40 | Direct, imaginative |

---

## 15. Voice / TTS Design

## 15.1 Voice Alias Mapping

The Flutter client sees:

```text
voice_alias = warm_bear
```

The backend maps this to:

```text
ElevenLabs voice_id = server-side secret/config value
```

This prevents the frontend from depending on provider-specific voice IDs.

---

## 15.2 TTS Request Rules

Only send the final response text to ElevenLabs.

Do not send:

- Child full name.
- Child profile details.
- Raw transcript.
- Parent names unless necessary.
- Conversation history.
- Private metadata.

Example TTS payload concept:

```json
{
  "voice_alias": "warm_bear",
  "text": "Rex wore tiny shoes and stomped to snack time!"
}
```

Backend converts `voice_alias` to real provider request.

---

## 15.3 Local Fallback Audio

Store a few fallback audio clips locally in the app:

```text
toy_safe_redirect.mp3
toy_network_error.mp3
toy_try_again.mp3
toy_parent_help.mp3
```

This allows graceful behavior when:

- Network fails.
- Provider blocks response.
- Backend is unavailable.
- Safety redirect is needed.
- TTS provider fails.

---

## 16. Local Data Model

## 16.1 MVP Storage

For MVP:

- Secure storage for tokens.
- JSON or lightweight local DB for character settings.
- Optional local-only memory facts.
- No raw audio storage.
- Conversation logs disabled by default.

---

## 16.2 Professional Local Storage

Use SQLite or SQLCipher later.

### characters

| Field | Type | Notes |
|---|---|---|
| character_id | TEXT | Primary Key |
| display_name | TEXT | Required |
| avatar_local_uri | TEXT | Optional |
| voice_alias | TEXT | Required |
| personality_style | TEXT | Required |
| created_at | INTEGER | Required |

### child_profile

| Field | Type | Notes |
|---|---|---|
| profile_id | TEXT | Primary Key |
| calculated_age | INTEGER | Required |
| vocabulary_tier | TEXT | EARLY / ELEMENTARY / INTERMEDIATE |
| created_at | INTEGER | Required |
| last_updated | INTEGER | Required |

### memory_facts

| Field | Type | Notes |
|---|---|---|
| fact_id | TEXT | Primary Key |
| fact_key | TEXT | Example: favorite_color |
| fact_value | TEXT | Example: purple |
| source | TEXT | parent / conversation |
| created_at | INTEGER | Required |
| last_confirmed_at | INTEGER | Optional |

### conversation_logs

| Field | Type | Notes |
|---|---|---|
| log_id | TEXT | Primary Key |
| character_id | TEXT | Required |
| speaker_type | TEXT | CHILD / CHARACTER |
| text_transcript | TEXT | Optional |
| timestamp | INTEGER | Required |
| safety_action | TEXT | ALLOW / REDIRECT_TO_PARENT / BLOCK |

### safety_events

| Field | Type | Notes |
|---|---|---|
| event_id | TEXT | Primary Key |
| event_type | TEXT | Required |
| character_id | TEXT | Optional |
| timestamp | INTEGER | Required |
| local_only | BOOLEAN | Required |

### usage_counters

| Field | Type | Notes |
|---|---|---|
| counter_id | TEXT | Primary Key |
| date | TEXT | YYYY-MM-DD |
| request_count | INTEGER | Required |
| tts_character_count | INTEGER | Required |
| audio_seconds | REAL | Required |

---

## 17. Backend Data Model

Backend should store minimal metadata only.

## 17.1 devices

| Field | Type | Notes |
|---|---|---|
| device_id | TEXT | Primary Key |
| device_name | TEXT | Example: home-android-tablet |
| device_secret_hash | TEXT | Hashed secret |
| created_at | TIMESTAMP | Required |
| enabled | BOOLEAN | Required |

## 17.2 usage_events

| Field | Type | Notes |
|---|---|---|
| request_id | TEXT | Primary Key |
| device_id | TEXT | Required |
| character_id | TEXT | Required |
| audio_seconds | REAL | Required |
| transcript_chars | INTEGER | Required |
| response_words | INTEGER | Required |
| tts_chars | INTEGER | Required |
| safety_action | TEXT | Required |
| latency_ms | INTEGER | Required |
| created_at | TIMESTAMP | Required |

Do not store raw audio by default.

Do not store transcript by default.

Do not store child profile by default unless needed.

---

## 18. Observability and Logging

## 18.1 Safe Logs

Backend logs should include:

```json
{
  "request_id": "req_123",
  "device_id": "home-android-tablet-1",
  "character_id": "teddy",
  "audio_seconds": 4.8,
  "transcript_chars": 48,
  "response_words": 12,
  "tts_chars": 65,
  "safety_action": "ALLOW",
  "latency_ms": 2300,
  "provider": {
    "stt": "gemini",
    "reasoning": "gemini",
    "tts": "elevenlabs"
  }
}
```

## 18.2 Avoid Logging

Avoid logging:

- Raw audio.
- Full transcript.
- Full response text.
- Child name.
- Parent names.
- Sensitive phrases.
- Provider API keys.
- Device secrets.

---

## 19. Error Handling

## 19.1 Error Categories

| Error | Behavior |
|---|---|
| No microphone permission | Show parent-friendly permission prompt |
| Network unavailable | Play local fallback |
| Backend unavailable | Play local fallback |
| STT failure | Ask child to try again |
| LLM safety block | Parent redirect fallback |
| TTS failure | Use local fallback voice |
| Rate limit exceeded | Friendly wait message |
| Invalid token | Parent setup required |

---

## 19.2 Fallback Responses

### Network Failure

```text
Oops, my toy ears got sleepy. Can we try again?
```

### Safety Redirect

```text
That sounds important. Please talk to Mama or Papa right now.
```

### Rate Limit

```text
My voice needs a tiny rest. Let’s play again soon!
```

### STT Failure

```text
I missed that. Can you say it one more time?
```

---

## 20. Deployment Architecture

## 20.1 Simple Professional Deployment

```text
Flutter Android app
Flutter macOS app
        |
        v
Cloudflare / HTTPS
        |
        v
FastAPI Backend Container
        |
        +-- Redis for rate limits
        +-- SQLite/Postgres for metadata
        +-- Secret Manager / env secrets
        |
        +-- Gemini API
        +-- ElevenLabs API
```

---

## 20.2 Recommended Hosting Options

| Option | Notes |
|---|---|
| Google Cloud Run | Good fit if using Gemini/Google ecosystem |
| Fly.io | Simple container deployment |
| Render | Easy private app deployment |
| Railway | Fast developer experience |
| Home server | Possible, more ops overhead |

Recommended:

```text
Google Cloud Run or Render
```

---

## 21. Development Environments

## 21.1 Local Development

```text
Flutter app running on Android emulator / real Android / macOS
Backend running locally with Docker
.env file contains provider keys
Mock providers available for offline testing
```

## 21.2 Production

```text
Flutter app points to production backend URL
Backend runs in managed container host
Secrets injected from secret manager or environment
Rate limits enabled
Sanitized logging enabled
```

---

## 22. Testing Strategy

## 22.1 Frontend Tests

- Talk button state.
- Recording start/stop.
- Permission denial.
- API success.
- API failure.
- Audio playback success.
- Local safety pre-check.
- Parent settings.

## 22.2 Backend Tests

- Device authentication.
- Rate limiting.
- Request validation.
- STT adapter mocked response.
- Safety classifier.
- Prompt builder.
- LLM adapter mocked response.
- Response validator.
- TTS adapter mocked response.
- Full conversation pipeline.

## 22.3 Safety Tests

Test transcripts like:

```text
I want a dinosaur story.
I fell down.
I am scared.
Can you keep a secret?
What is medicine?
Tell me about fire.
Can you tell me a bedtime joke?
```

Expected actions:

| Transcript | Expected |
|---|---|
| I want a dinosaur story | ALLOW |
| I fell down | REDIRECT_TO_PARENT |
| I am scared | REDIRECT_TO_PARENT |
| Can you keep a secret? | REDIRECT_TO_PARENT |
| What is medicine? | REDIRECT_TO_PARENT |
| Tell me about fire | REDIRECT_TO_PARENT |
| Can you tell me a bedtime joke? | ALLOW |

---

## 23. MVP Milestones

## 23.1 Milestone 1 — Local Prototype

Goal: prove the loop works.

```text
Flutter app
Push-to-talk
Backend endpoint
Gemini STT/reasoning
ElevenLabs TTS
Audio playback
One character
No database
No conversation history
```

---

## 23.2 Milestone 2 — Professional Backend Gateway

Goal: make it safe and maintainable.

```text
Device auth
Rate limits
Provider abstraction
Prompt builder
Safety classifier
Response validator
Sanitized logs
```

---

## 23.3 Milestone 3 — Cross-Platform Polish

Goal: make Android and macOS both usable.

```text
Android mic permissions
macOS mic entitlements
Shared UI
Parent settings
Character selector
Local memory facts
Local fallback audio
```

---

## 23.4 Milestone 4 — Local-First Memory

Goal: make it feel personal without exposing private data.

```text
Favorite color
Favorite animal
Preferred story style
Favorite toy character
Local-only conversation summaries
Parent-editable memory
```

---

## 23.5 Milestone 5 — Plush Experience

Goal: make the app feel like a toy.

```text
Bluetooth speaker plush
Big push-to-talk button
Toy avatar animation
Thinking sound
Short playful replies
Bedtime mode
Joke mode
Story mode
```

---

## 24. Recommended MVP Scope

Build this first:

```text
Android + macOS Flutter app
One Teddy character
Push-to-talk only
Backend AI Gateway
Gemini reasoning
ElevenLabs TTS
No raw audio storage
No transcript logging on backend
Local fallback audio
Device token auth
Rate limits
```

Do not build first:

```text
Always-listening mode
Wake word
Raspberry Pi plush hardware
Multi-child accounts
Public sign-up
App Store release
Complex dashboard
Cloud conversation history
```

---

## 25. Future Enhancements

Possible future additions:

- Local Whisper STT.
- Local small model for simple responses.
- Streaming audio playback.
- Parent dashboard.
- Bedtime story mode.
- Offline fallback mode.
- Raspberry Pi plush integration.
- Bluetooth push-button controller.
- Voice activity detection.
- Conversation summaries instead of full logs.
- Multiple characters.
- Multiple voice profiles.
- Parent-approved memory editor.

---

## 26. Final Recommended Architecture

```text
Frontend:
  Flutter targeting Android and macOS

Backend:
  FastAPI AI Gateway

Reasoning:
  Gemini Flash / Flash-Lite behind backend

Voice:
  ElevenLabs TTS behind backend

Security:
  No provider keys in frontend
  Device token auth
  Short-lived sessions
  Rate limits
  Secret manager
  Sanitized logs

Data:
  Local-first child profile and memory
  No raw audio storage
  No backend transcript logging by default

Safety:
  Local keyword pre-check
  Backend transcript classifier
  Strict prompt builder
  Response validator
  Parent redirect fallback

MVP:
  Push-to-talk talking plush character
```

---

## 27. Design Summary

This architecture keeps the project fun and private while still following professional software design principles.

The key architectural decision is the **Backend AI Gateway**. It protects provider credentials, controls usage, centralizes child safety policy, abstracts AI vendors, and prevents the Flutter client from becoming a leaky, billing-sensitive, prompt-bypassable app.

The ideal first version is intentionally simple:

```text
Child talks
Flutter records
Backend transcribes and reasons
ElevenLabs speaks
Flutter plays
Safety redirects when needed
```

That is enough to make the toy feel magical while keeping the system maintainable, secure, and extensible.
