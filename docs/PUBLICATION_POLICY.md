# ToyTalk documentation publication policy

Last updated: 2026-07-05

This repository is public. Documentation in the repo should help someone clone,
build, run, evaluate, or understand ToyTalk without exposing private family
data, private learning notes, credentials, local samples, or heavyweight
generated outputs.

## Public docs that belong in git

These documents are intended to be published:

- `README.md` — project overview, screenshots, quick start, release links, and
  current status.
- `docs/architecture/SYSTEM_DESIGN.md` — canonical current system design.
- `docs/architecture/CODEBASE_DIRECTORY_GUIDE.md` — canonical code/directory
  map.
- `docs/architecture/HUB_CLIENT_ARCHITECTURE.md` — Hub/client MVP-specific
  architecture notes.
- `docs/product/*` — public privacy, security, and known-limitations docs.
- `docs/release/*` — public QA plans, release checklists, traceability, and
  repository settings.
- `docs/adr/*` — public architecture decision records.
- `docs/implementation/PRODUCTION_HARDENING_PLAN.md` — public hardening plan.

## Private/local docs that should not be published

Keep these outside the git checkout, preferably under
`~/Downloads/ToyTalk/private`:

- personal system-design interview prep notes;
- stale product specs, archived design notes, and historical execution plans;
- private family context or child-specific notes;
- private voice samples and listening bakeoff outputs;
- provider API keys, tokens, `.env` files, provisioning profiles, and signing
  material;
- generated build artifacts, model caches, QA evidence, screenshots containing
  private data, and local database snapshots.

The current private copy of the removed interview-prep document is stored at:

```text
~/Downloads/ToyTalk/private/reference-docs/SYSTEM_DESIGN_INTERVIEW_PREP.md
```

## Current canonical architecture

The public docs should describe this architecture consistently:

1. ToyTalk Hub is the local private backend and durable encrypted store.
2. Android, iPhone, Mac app, and future Windows/Linux apps are thin native UI
   clients that pair with Hub.
3. Local browser is supported only on the same machine running Hub; remote
   browser clients are out of scope.
4. Hub owns parent settings, kids, characters, conversations, runtime mode,
   provider keys, guardrails, local/cloud reasoning, LuxTTS, local STT fallback,
   and SQLCipher storage.
5. Clients own UI, mic capture, verified local STT when available, playback, and
   minimum pairing/session identity.
6. Voice samples do not go to Gemini/OpenAI; Cloud AI mode receives only
   minimized, pseudonymized text context.
7. Build artifacts and release bundles are generated outside the repo under
   `~/Downloads/ToyTalk`, and downloadable binaries are published through
   GitHub Releases rather than committed to git.

## Before adding a new document

Ask:

1. Is this current product/repo documentation, or personal learning material?
2. Does it mention private names, samples, keys, local absolute paths, or
   unpublished family data?
3. Is it canonical, historical, or archived? Label it clearly.
4. Does it duplicate another doc in a way that could become stale?
5. Should it live in public docs or `~/Downloads/ToyTalk/private`? If it is
   stale or historical, keep it private/local rather than publishing it.
