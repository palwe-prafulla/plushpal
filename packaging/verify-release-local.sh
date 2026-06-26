#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACTS_ROOT=${PLUSHPAL_ARTIFACTS_DIR:-"$ROOT/dist"}
BUILD_ROOT=${PLUSHPAL_BUILD_DIR:-"$ROOT/build"}
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$BUILD_ROOT/cargo-target"}
export PLUSHPAL_ARTIFACTS_DIR="$ARTIFACTS_ROOT"
export PLUSHPAL_BUILD_DIR="$BUILD_ROOT"
export CARGO_TARGET_DIR
cd "$ROOT"

command -v cargo >/dev/null
command -v cmake >/dev/null
command -v flutter >/dev/null
command -v node >/dev/null
command -v zip >/dev/null

make public-repo-check
make doctor
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p plushpal-desktop-host --example model_smoke --features native-runtime
cargo check -p plushpal-desktop-host --example voice_smoke --features native-runtime

cmake -S native/key_vault_abi -B "$BUILD_ROOT/native-key-vault" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build "$BUILD_ROOT/native-key-vault" --config Release -j 4
ctest --test-dir "$BUILD_ROOT/native-key-vault" --output-on-failure

cmake -S native/llama_abi -B "$BUILD_ROOT/native-llama" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
  -DPLUSHPAL_LLAMA_CPP_DIR="${PLUSHPAL_LLAMA_CPP_DIR:-$ROOT/third_party/llama.cpp}"
cmake --build "$BUILD_ROOT/native-llama" --config Release -j 4
ctest --test-dir "$BUILD_ROOT/native-llama" --output-on-failure

(cd apps/android/flutter_app && flutter analyze && flutter test)
node --check apps/android/flutter_app/web/plushpal_backend.js
node --check apps/android/flutter_app/web/audio_normalization.js
node --test apps/android/flutter_app/test/audio_normalization_test.js
xcrun swiftc -parse apps/android/flutter_app/ios/Runner/PlushPalPlatformPlugin.swift

sh packaging/macos/package.sh
test -f apps/android/flutter_app/build/web/assets/assets/fonts/Roboto-Regular.ttf
codesign --verify --deep --strict --verbose=2 "$ARTIFACTS_ROOT/macos/PlushBuddy Station.app"
otool -L "$ARTIFACTS_ROOT/macos/PlushBuddy Station.app/Contents/MacOS/plushpal-desktop-host" | \
  grep -F '@rpath/libplushpal_llama.dylib' >/dev/null
otool -l "$ARTIFACTS_ROOT/macos/PlushBuddy Station.app/Contents/MacOS/plushpal-desktop-host" | \
  grep -F '@executable_path/../Frameworks' >/dev/null

if rg -n --hidden \
  -g '!third_party/**' -g '!target/**' -g '!dist/**' -g '!build/**' \
  -g '!apps/android/flutter_app/build/**' -g '!models/**' \
  '(sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' .; then
  echo 'Potential credential material found in tracked source.' >&2
  exit 1
fi

git diff --check
shasum -a 256 \
  "$ARTIFACTS_ROOT/macos/PlushBuddy-0.1.0-macos.zip" \
  "$ARTIFACTS_ROOT/macos/PlushBuddy Station.app/Contents/MacOS/PlushBuddy Station" \
  "$ARTIFACTS_ROOT/macos/PlushBuddy Station.app/Contents/Frameworks/libplushpal_llama.dylib"
