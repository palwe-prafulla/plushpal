# ADR-001: Shared Rust core boundaries

- Status: Accepted for bootstrap
- Date: 2026-06-18
- Owners: Technical lead; iOS, Android, desktop, and inference owners

## Context

PlushPal must reuse conversation policy and orchestration across mobile and desktop while keeping platform SDKs, secrets, and audio lifecycle behavior outside shared presentation code.

## Decision

The shared Rust workspace owns domain types, age policy, conversation orchestration, provider/search interfaces, and repository contracts. Flutter is presentation only. Swift, Kotlin, and the desktop host own platform capabilities. llama.cpp and speech engines will be integrated behind narrow native adapters.

External cloud and search adapters receive separate allowlisted transfer objects. They cannot query storage or receive voice assets, audio, exact age, real names, or unrestricted history.

## Consequences

The bootstrap can be tested without platform SDKs or a model runtime. Stable C and generated application-client boundaries must be added before mobile integration. Platform exceptions require a follow-up ADR rather than conditional policy in Flutter.

## Evidence required

- Rust workspace formatting, lint, and unit tests.
- C ABI cancellation and ownership spike.
- Network serialization allowlist tests.
- Device benchmarks for the selected local model tiers.

