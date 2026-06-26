# PlushBuddy documentation publication policy

Last updated: 2026-06-26

This repository is public. Documentation in the repo should help someone clone,
build, run, evaluate, or understand PlushBuddy without exposing private family
data, private learning notes, credentials, local samples, or heavyweight
generated outputs.

## Public docs that belong in git

These documents are intended to be published:

- `README.md` — project overview, screenshots, quick start, release links, and
  current status.
- `docs/architecture/SYSTEM_DESIGN.md` — canonical current system design.
- `docs/architecture/CODEBASE_DIRECTORY_GUIDE.md` — canonical code/directory
  map.
- `docs/architecture/ANDROID_MACSTATION_MVP_ARCHITECTURE.md` — MVP-specific
  architecture notes.
- `docs/product/*` — public privacy, security, and known-limitations docs.
- `docs/release/*` — public QA plans, release checklists, traceability, and
  repository settings.
- `docs/adr/*` — public architecture decision records.
- `docs/implementation/PRODUCTION_HARDENING_PLAN.md` — public hardening plan.
- `docs/implementation/EXECUTION_PLAN.md` — historical implementation log,
  retained only with a clear non-canonical banner.
- `docs/specifications/*` and `docs/archive/*` — historical specs/archives, only
  when clearly labeled as not the current source of truth.

## Private/local docs that should not be published

Keep these outside the git checkout, preferably under
`~/Downloads/PlushPal/private`:

- personal system-design interview prep notes;
- private family context or child-specific notes;
- private voice samples and listening bakeoff outputs;
- provider API keys, tokens, `.env` files, provisioning profiles, and signing
  material;
- generated build artifacts, model caches, QA evidence, screenshots containing
  private data, and local database snapshots.

The current private copy of the removed interview-prep document is stored at:

```text
~/Downloads/PlushPal/private/reference-docs/SYSTEM_DESIGN_INTERVIEW_PREP.md
```

## Current canonical architecture

The public docs should describe this architecture consistently:

1. Android, iPhone, browser, and Mac client are the user-facing app surfaces.
2. The Flutter client owns parent settings, kids, characters, conversation
   history, provider selection, API keys, cloud reasoning, and playback.
3. MacStation is a local Mac voice appliance, not the main app backend.
4. MacStation owns LuxTTS setup, voice profile creation, encrypted processed
   voice references, voice preview/approval support, and TTS synthesis.
5. Browser and Mac client opened from Station auto-attach locally without QR.
6. Android and iPhone pair with Station through QR because they are external
   devices on the local network.
7. Voice samples do not go to Gemini/OpenAI; cloud LLMs receive only minimized,
   pseudonymized text context.
8. Build artifacts and release bundles are generated outside the repo under
   `~/Downloads/PlushPal`, and downloadable binaries are published through
   GitHub Releases rather than committed to git.

## Before adding a new document

Ask:

1. Is this current product/repo documentation, or personal learning material?
2. Does it mention private names, samples, keys, local absolute paths, or
   unpublished family data?
3. Is it canonical, historical, or archived? Label it clearly.
4. Does it duplicate another doc in a way that could become stale?
5. Should it live in public docs, `docs/archive`, or
   `~/Downloads/PlushPal/private`?
