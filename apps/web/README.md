# ToyTalk Browser Client

The browser app is a local ToyTalk client for the same computer running
**ToyTalk Hub**. It uses the same shared Flutter UI as Android, iPhone, and
the Mac client, but it is intentionally **not** a remote LAN browser product in
the current architecture.

Current browser ownership:

- durable parent setup, kids, characters, Cloud AI provider keys, conversation
  history, voice profile metadata, and guardrails live in ToyTalk Hub;
- the browser stores only local bootstrap/session identity plus normal browser
  runtime state;
- Gemini/OpenAI reasoning is called by Hub after redaction and guardrails, not
  directly by the browser;
- Local AI is also run by Hub through the configured local model;
- voice enrollment, preview/approval, and text-to-speech WAV generation are Hub
  APIs backed by LuxTTS;
- the browser session is opened from Hub on `localhost` and bootstrapped from a
  Hub URL containing `#bootstrap=...`, which is exchanged for a local Hub
  session cookie.

Remote browsers from phones or other PCs are out of scope for now. Use native
Android/iPhone/Mac clients for other devices.

The UI is built from the shared Flutter app in:

```text
apps/android/flutter_app/
```

Flutter expects the web shell to live inside the Flutter project:

```text
apps/android/flutter_app/web/
```

When the browser app is built, the generated Flutter web bundle is copied into
the Hub host:

```text
apps/station/macstation_host/assets/flutter_web/
```

Build command:

```sh
make desktop
```

Full packaged app command:

```sh
make package-macos
```

Useful source files:

```text
apps/android/flutter_app/lib/src/app.dart
apps/android/flutter_app/lib/src/backend/backend_client_web.dart
apps/android/flutter_app/web/plushpal_backend.js
apps/android/flutter_app/web/audio_normalization.js
apps/android/flutter_app/test/plushpal_backend_web_test.mjs
```

Do not hand-edit generated files under `apps/station/macstation_host/assets/flutter_web/`; rebuild from the Flutter source instead.
