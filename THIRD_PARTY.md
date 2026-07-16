# Third-party components

ToyTalk combines app code, local model/runtime integrations, and optional
cloud provider APIs. Check each third-party component's license and terms before
redistributing production builds.

## Included or referenced source/runtime components

| Component | How it is used | Notes |
|---|---|---|
| Flutter / Dart | Shared Android, iPhone, browser UI | Managed through Flutter tooling. |
| Rust crates | ToyTalk Hub host, shared domain/provider/storage logic | Managed through Cargo. |
| Axum / Tokio | Local ToyTalk Hub HTTP/WebSocket host | Managed through Cargo. |
| llama.cpp | Pinned submodule for local reasoning experiments/fallbacks | Keep upstream license files with the submodule. |
| LuxTTS | Downloaded/prepared by ToyTalk Hub setup for local voice synthesis | Stored outside the repo in user-local support/cache locations. Review upstream license/model card before redistribution. |
| LinaCodec / torch / torchaudio / transformers / onnxruntime / librosa and related Python packages | LuxTTS runtime dependencies | Prepared by ToyTalk Hub setup rather than committed to the source repo. |
| Gemini API | Optional parent-configured cloud reasoning provider | Users provide their own key and accept provider terms. |
| OpenAI API | Optional parent-configured cloud reasoning provider | Users provide their own key and accept provider terms. |

## Private data warning

Do not include private child photos, private voice samples, generated voice
profiles, local API keys, model caches, or build/test artifacts in public
commits or public release assets unless you have explicit consent and have
reviewed the applicable provider/model terms.

## Release note

The local `make public-artifacts` command writes generated apps outside the
source repository under `~/Downloads/ToyTalk/artifacts`. Heavy model/runtime
payloads are prepared by ToyTalk Hub setup instead of being committed to git.
