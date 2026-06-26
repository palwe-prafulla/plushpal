# Third-party components

PlushBuddy combines app code, local model/runtime integrations, and optional
cloud provider APIs. Check each third-party component's license and terms before
redistributing production builds.

## Included or referenced source/runtime components

| Component | How it is used | Notes |
|---|---|---|
| Flutter / Dart | Shared Android, iPhone, browser UI | Managed through Flutter tooling. |
| Rust crates | MacStation host, shared domain/provider/storage logic | Managed through Cargo. |
| Axum / Tokio | Local MacStation HTTP/WebSocket host | Managed through Cargo. |
| llama.cpp | Pinned submodule for local reasoning experiments/fallbacks | Keep upstream license files with the submodule. |
| LuxTTS | Downloaded by public build/setup scripts for local voice synthesis | Downloaded under `~/Downloads/PlushPal/deps` or bundled into local artifacts. Review upstream license/model card before redistribution. |
| LinaCodec / torch / torchaudio / transformers / onnxruntime / librosa and related Python packages | LuxTTS runtime dependencies | Installed into the packaged local Station runtime during macOS artifact creation. |
| Gemini API | Optional parent-configured cloud reasoning provider | Users provide their own key and accept provider terms. |
| OpenAI API | Optional parent-configured cloud reasoning provider | Users provide their own key and accept provider terms. |

## Private data warning

Do not include private child photos, private voice samples, generated voice
profiles, local API keys, model caches, or build/test artifacts in public
commits or public release assets unless you have explicit consent and have
reviewed the applicable provider/model terms.

## Release note

The local `make public-artifacts` command creates large macOS artifacts because
it bundles the local Python/LuxTTS runtime. Those artifacts are intentionally
written outside the source repository under `~/Downloads/PlushPal/artifacts`.
