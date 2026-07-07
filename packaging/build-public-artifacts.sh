#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PUBLIC_ROOT=${PLUSHPAL_PUBLIC_ROOT:-"$HOME/Downloads/ToyTalk"}
BUILD_ROOT=${PLUSHPAL_BUILD_DIR:-"$PUBLIC_ROOT/build"}
ARTIFACTS_ROOT=${PLUSHPAL_ARTIFACTS_DIR:-"$PUBLIC_ROOT/artifacts"}
WORKTREE="$BUILD_ROOT/source"
VERSION=${PLUSHPAL_VERSION:-}

if [ -z "$VERSION" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)
  else
    VERSION="local"
  fi
fi

mkdir -p "$BUILD_ROOT" "$ARTIFACTS_ROOT"

echo "Preparing external build workspace at $WORKTREE"
rm -rf "$WORKTREE"
mkdir -p "$WORKTREE"

rsync -a --delete "$ROOT/" "$WORKTREE/" \
  --exclude '.git/' \
  --exclude '.idea/' \
  --exclude '.vscode/' \
  --exclude '*.iml' \
  --exclude '.venv*/' \
  --exclude '.dart_tool/' \
  --exclude '.flutter-plugins' \
  --exclude '.flutter-plugins-dependencies' \
  --exclude '.metadata' \
  --exclude '.gradle/' \
  --exclude 'local.properties' \
  --exclude 'DerivedData/' \
  --exclude 'Pods/' \
  --exclude '.symlinks/' \
  --exclude 'build/' \
  --exclude 'dist/' \
  --exclude 'target/' \
  --exclude 'desktop_host/' \
  --exclude 'audio-samples/' \
  --exclude 'test-artifacts/' \
  --exclude 'test-results/' \
  --exclude 'qa/results/' \
  --exclude 'models/runtime/' \
  --exclude 'models/downloads/' \
  --exclude 'models/cache/' \
  --exclude 'third_party/GPT-SoVITS/' \
  --exclude 'third_party/LuxTTS/' \
  --exclude 'third_party/OpenVoice/' \
  --exclude 'third_party/tada/' \
  --exclude 'gemiapi'

export PLUSHPAL_PUBLIC_ROOT="$PUBLIC_ROOT"
export PLUSHPAL_BUILD_DIR="$BUILD_ROOT"
export PLUSHPAL_ARTIFACTS_DIR="$ARTIFACTS_ROOT"
export PLUSHPAL_VERSION="$VERSION"
export CARGO_TARGET_DIR="$BUILD_ROOT/cargo-target-public"
export PACKAGE_CARGO_TARGET_DIR="$BUILD_ROOT/cargo-target-public"

cd "$WORKTREE"

echo "Building macOS ToyTalk Hub and Mac client artifacts..."
if [ "${PLUSHPAL_SKIP_MACOS:-0}" = "1" ]; then
  echo "Skipping macOS artifacts because PLUSHPAL_SKIP_MACOS=1"
else
  make \
    PUBLIC_ROOT="$PUBLIC_ROOT" \
    ARTIFACTS_DIR="$ARTIFACTS_ROOT" \
    BUILD_DIR="$BUILD_ROOT" \
    PACKAGE_CARGO_TARGET_DIR="$PACKAGE_CARGO_TARGET_DIR" \
    package-macos
fi

echo "Building Android APK..."
if [ "${PLUSHPAL_SKIP_ANDROID:-0}" = "1" ]; then
  echo "Skipping Android APK because PLUSHPAL_SKIP_ANDROID=1"
elif command -v cargo-ndk >/dev/null 2>&1; then
  make \
    PUBLIC_ROOT="$PUBLIC_ROOT" \
    ARTIFACTS_DIR="$ARTIFACTS_ROOT" \
    BUILD_DIR="$BUILD_ROOT" \
    PACKAGE_CARGO_TARGET_DIR="$PACKAGE_CARGO_TARGET_DIR" \
    android-apk
  mkdir -p "$ARTIFACTS_ROOT/android"
  cp apps/android/flutter_app/build/app/outputs/flutter-apk/app-debug.apk \
    "$ARTIFACTS_ROOT/android/ToyTalk-debug.apk"
else
  echo "warning: cargo-ndk not found; skipping Android APK. Install cargo-ndk and rerun for Android artifacts." >&2
fi

echo "Building iPhone simulator and unsigned device apps..."
if [ "${PLUSHPAL_SKIP_IOS:-0}" = "1" ]; then
  echo "Skipping iPhone artifacts because PLUSHPAL_SKIP_IOS=1"
elif command -v xcodebuild >/dev/null 2>&1; then
  make \
    PUBLIC_ROOT="$PUBLIC_ROOT" \
    ARTIFACTS_DIR="$ARTIFACTS_ROOT" \
    BUILD_DIR="$BUILD_ROOT" \
    PACKAGE_CARGO_TARGET_DIR="$PACKAGE_CARGO_TARGET_DIR" \
    ios-simulator
  make \
    PUBLIC_ROOT="$PUBLIC_ROOT" \
    ARTIFACTS_DIR="$ARTIFACTS_ROOT" \
    BUILD_DIR="$BUILD_ROOT" \
    PACKAGE_CARGO_TARGET_DIR="$PACKAGE_CARGO_TARGET_DIR" \
    ios-device
  mkdir -p "$ARTIFACTS_ROOT/ios"
  rsync -a --delete apps/android/flutter_app/build/ios/iphonesimulator/Runner.app/ \
    "$ARTIFACTS_ROOT/ios/ToyTalk-iPhoneSimulator.app/"
  rsync -a --delete apps/android/flutter_app/build/ios/iphoneos/Runner.app/ \
    "$ARTIFACTS_ROOT/ios/ToyTalk-iPhoneOS-unsigned.app/"
else
  echo "warning: Xcode command line tools not found; skipping iPhone artifacts." >&2
fi

cat > "$ARTIFACTS_ROOT/README.txt" <<EOF
ToyTalk local build artifacts

Built from: $ROOT
Build workspace: $WORKTREE

macOS:
  $ARTIFACTS_ROOT/macos/ToyTalk Hub.app
  $ARTIFACTS_ROOT/macos/ToyTalk.app
  $ARTIFACTS_ROOT/macos/ToyTalk-*.zip
  $ARTIFACTS_ROOT/macos/ToyTalk-*.dmg, when hdiutil is available

Android:
  $ARTIFACTS_ROOT/android/ToyTalk-debug.apk, when Android SDK/NDK and cargo-ndk are available

iPhone:
  $ARTIFACTS_ROOT/ios/ToyTalk-iPhoneSimulator.app
  $ARTIFACTS_ROOT/ios/ToyTalk-iPhoneOS-unsigned.app

EOF

echo "Artifacts are ready under $ARTIFACTS_ROOT"
