#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUTPUT="$ROOT/apps/android/flutter_app/build/mobile-rust"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

command -v cargo-ndk >/dev/null 2>&1 || {
  echo "cargo-ndk is required for Android Rust builds" >&2
  exit 1
}

detect_android_ndk() {
  for sdk in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${NDK_HOME:-}"; do
    if [ -n "$sdk" ] && [ -d "$sdk/toolchains/llvm/prebuilt" ]; then
      printf '%s\n' "$sdk"
      return 0
    fi
  done
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    if [ -n "$sdk" ] && [ -d "$sdk/ndk" ]; then
      found=$(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)
      if [ -n "$found" ] && [ -d "$found/toolchains/llvm/prebuilt" ]; then
        printf '%s\n' "$found"
        return 0
      fi
    fi
  done
  return 1
}

ANDROID_NDK_HOME=$(detect_android_ndk || true)
if [ -z "$ANDROID_NDK_HOME" ]; then
  echo "Android NDK not found. Install it with Android Studio SDK Manager, then rerun make android-apk." >&2
  exit 1
fi
export ANDROID_NDK_HOME

cd "$ROOT"
export CARGO_TARGET_DIR
FEATURES=""
if [ "${PLUSHPAL_ANDROID_NATIVE_RUNTIME:-0}" = "1" ]; then
  FEATURES="--features native-runtime"
fi
cargo ndk --platform 29 --target arm64-v8a --target x86_64 \
  build --release \
  -p plushpal-mobile-bridge $FEATURES

mkdir -p "$OUTPUT/arm64-v8a" "$OUTPUT/x86_64"
cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/libplushpal_mobile_bridge.a" \
  "$OUTPUT/arm64-v8a/libplushpal_mobile_bridge.a"
cp "$CARGO_TARGET_DIR/x86_64-linux-android/release/libplushpal_mobile_bridge.a" \
  "$OUTPUT/x86_64/libplushpal_mobile_bridge.a"
