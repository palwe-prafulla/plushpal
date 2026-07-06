# Third-Party and Model License Ledger

This ledger must be regenerated and reviewed for every release; binary SBOM generation is a release gate.

| Component | Pin/source | License obligation |
|---|---|---|
| llama.cpp | Git submodule tag `b9637`, commit `aedb2a5e9ca3d4064148bbb919e0ddc0c1b70ab3` | MIT notice |
| Gemma 4 E4B Q4 | Official Google GGUF; 5,154,939,136 bytes; SHA-256 `e8b6a059ba86947a44ace84d6e5679795bc41862c25c30513142588f0e9dba1d` | Gemma Terms of Use; retain model card and attribution; quality, safety, performance, redistribution, and legal approval required before distribution |
| Gemma 4 12B Q4 | Official Google GGUF; 6,975,877,728 bytes; SHA-256 `faff1a63667fac17ac5e777f47114688fcefea96e220e211aaa8d62c2c4561f1` | Gemma Terms of Use; retain model card and attribution; quality, safety, performance, redistribution, and legal approval required before distribution |
| Gemma 4 26B A4B Q4 | Official Google GGUF; 14,439,361,440 bytes; SHA-256 `4c856523d61d77922dbc0b26753a6bf6208e5d69d80db0c04dcd776832d054c5` | Gemma Terms of Use; retain model card and attribution; quality, safety, performance, redistribution, and legal approval required before distribution |
| sherpa-onnx | Rust crate/runtime pinned by `Cargo.lock` | Apache-2.0 runtime notices; generate SBOM and target-specific native notices |
| Chatterbox TTS | Optional local Python runtime installed by `tools/voice/setup_chatterbox_macos.sh`; exact package/model lockfile and model-cache hashes must be captured before distribution | Upstream materials describe the Chatterbox family as MIT licensed and suitable for commercial/on-prem use; legal must verify package dependencies, model weights, watermark obligations, and notices before bundling |
| Pocket TTS ONNX development model | Separately downloaded development fixture; archive SHA-256 `2f3b88823cbbb9bf0b2477ec8ae7b3fec417b3a87b6bb5f256dba66f2ad967cb` | **Do not bundle or ship.** Published model README states non-commercial use. Development testing only pending replacement by a redistribution-approved model |
| Flutter/Dart | Toolchain and packages in `pubspec.lock` | Preserve applicable notices in bundled `NOTICES` |
| Roboto font | Flutter SDK material-font artifact, copied into the app for offline rendering | Apache-2.0; preserve the font license in bundled notices |
| Rust crates | Exact versions in `Cargo.lock` | Generate SPDX/CycloneDX SBOM and preserve all required notices |
| SQLCipher/OpenSSL-derived bundled code | Via pinned `rusqlite`/`libsqlite3-sys` feature graph | Review SQLCipher and cryptographic-library notices for each target |

No model URL, hash, or license is accepted from UI input. Only a signed manifest controlled by the release process may activate a model. The checked-in key is a private-beta trust root and must be replaced by an offline production signing root before public distribution.
