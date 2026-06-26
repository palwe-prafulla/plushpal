# Security Policy

PlushBuddy is an experimental local-first voice companion. Please treat child
data, voice samples, photos, and provider API keys as sensitive.

## Supported versions

This repository is pre-1.0. Security fixes should target `main` unless release
branches are created later.

## Reporting a vulnerability

If you find a vulnerability, please do not publish exploit details in a public
issue first. Open a private GitHub security advisory when the repository is on
GitHub, or contact the repository owner directly.

Useful reports include:

- impacted platform: Android, iPhone, browser, Mac client, or MacStation;
- reproduction steps;
- whether private audio/photo/profile/API-key data can be exposed;
- logs with secrets redacted.

## Secret handling

Never commit:

- Gemini/OpenAI/other provider API keys;
- `.env` files;
- Android keystores or Apple signing material;
- private audio samples or child photos;
- generated voice profiles;
- downloaded model/runtime caches.

The repository `.gitignore` is configured to avoid common local artifacts, but
contributors should still review `git status` and run a secret scan before
pushing.
