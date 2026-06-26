# Unit test inventory

Unit tests remain close to the code under test:

- Flutter/client unit and widget tests: `apps/android/flutter_app/test/`
- Android JVM/native validation tests: `apps/android/flutter_app/android/app/src/test/`
- Rust domain, MacStation, storage, policy, and voice-route tests: `crates/**/tests` and crate-local `#[cfg(test)]` modules
- Native ABI tests: `native/**/tests/`
- Packaging layout test: `packaging/macos/tests/`

Run the main unit/build checks from the repository root:

```sh
cargo test --workspace
cd apps/android/flutter_app && flutter analyze && flutter test
cd apps/android/flutter_app && node --test test/audio_normalization_test.js test/plushpal_backend_web_test.mjs
make test-product-layout
```

