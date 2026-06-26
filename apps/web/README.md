# PlushBuddy Browser Client

The browser app is a first-class PlushBuddy client, parallel to the Android app.
It is served by MacStation, but it does not make MacStation the app backend.

Browser ownership:

- parent setup, kids, characters, API key, and conversation history live in the browser;
- Gemini/OpenAI reasoning is called directly from the browser;
- MacStation is used only for voice profile creation, voice preview/approval, and text-to-speech WAV generation;
- the browser session is bootstrapped from a MacStation URL containing `#bootstrap=...`, which is exchanged for a local Station session cookie.

Current browser storage note: browser data is kept in localStorage. Android uses encrypted native storage; browser-side encryption is a future hardening item.

The UI is built from the shared Flutter app in:

```text
apps/android/flutter_app/
```

Flutter expects the web shell to live inside the Flutter project:

```text
apps/android/flutter_app/web/
```

When the browser app is built, the generated Flutter web bundle is copied into the MacStation host:

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
