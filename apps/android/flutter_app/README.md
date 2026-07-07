# ToyTalk shared Flutter client

This Flutter project contains the shared client UI for:

- Android;
- iPhone/iOS;
- local browser client served by ToyTalk Hub;
- the Mac client WebView shell.

The client is intentionally thin. It renders parent setup, kid/character
management, child mode, theme, pairing, mic/file-picker flows, and playback, but
durable family data lives in ToyTalk Hub.

## Main files

```text
lib/src/app.dart                         main UI and state orchestration
lib/src/domain/app_state.dart            state reducer
lib/src/backend/backend_client.dart      backend interface
lib/src/backend/backend_client_stub.dart native Hub HTTP client bridge
lib/src/backend/backend_client_web.dart  local browser Hub wrapper
android/app/src/main/kotlin/...          Android platform bridge
ios/Runner/PlushPalPlatformPlugin.swift  iOS platform bridge
web/plushpal_backend.js                  browser bridge to Hub APIs
test/                                    unit/widget/backend tests
```

## Local checks

```sh
flutter analyze
flutter test
flutter build apk --debug
```

## Architecture note

Android/iPhone/browser clients store only stable client identity,
Hub pairing/session state, theme/UI preferences, and temporary OS helper state.
Parent PIN, Cloud AI keys, kids, characters, voice profile metadata,
conversation history, local/cloud reasoning, and LuxTTS synthesis are owned by
ToyTalk Hub.
