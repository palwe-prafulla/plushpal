#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=${PLUSHPAL_VERSION:-0.1.0}
ARCHIVE_TIMESTAMP=${PLUSHPAL_ARCHIVE_TIMESTAMP:-202601010000}
ARTIFACTS_ROOT=${PLUSHPAL_ARTIFACTS_DIR:-"$ROOT/dist"}
BUILD_ROOT=${PLUSHPAL_BUILD_DIR:-"$ROOT/build"}
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/target"}
LUXTTS_SOURCE_DIR=${PLUSHPAL_LUXTTS_SOURCE_DIR:-"$ROOT/third_party/LuxTTS"}
OUTPUT="$ARTIFACTS_ROOT/macos"
STATION_APP="$OUTPUT/PlushBuddy Station.app"
CLIENT_APP="$OUTPUT/PlushBuddy.app"
export CARGO_TARGET_DIR

if [ -n "${PLUSHPAL_CODESIGN_IDENTITY:-}" ] && [ -z "${PLUSHPAL_TEAM_ID:-}" ]; then
  echo 'PLUSHPAL_TEAM_ID is required with PLUSHPAL_CODESIGN_IDENTITY.' >&2
  exit 1
fi

cd "$ROOT/apps/android/flutter_app"
flutter build web --release --pwa-strategy=none --no-web-resources-cdn
rsync -a --delete build/web/ "$ROOT/apps/station/macstation_host/assets/flutter_web/"

cd "$ROOT"
cargo build --release -p plushpal-desktop-host --features native-runtime

rm -rf "$STATION_APP" "$CLIENT_APP" "$OUTPUT/PlushPal.app"
mkdir -p "$OUTPUT" "$BUILD_ROOT"

mkdir -p "$CLIENT_APP/Contents/MacOS" "$CLIENT_APP/Contents/Resources"
swiftc -O \
  -framework AppKit \
  -framework WebKit \
  apps/macos/client_app/AppShell.swift \
  -o "$CLIENT_APP/Contents/MacOS/PlushBuddy"
sed "s/@VERSION@/$VERSION/g" packaging/macos/ClientInfo.plist.in > "$CLIENT_APP/Contents/Info.plist"

mkdir -p "$STATION_APP/Contents/MacOS" "$STATION_APP/Contents/Resources" "$STATION_APP/Contents/Frameworks"
swiftc -O \
  -framework AppKit \
  -framework CoreImage \
  -framework Security \
  -framework WebKit \
  apps/macos/station_app/AppShell.swift \
  -o "$STATION_APP/Contents/MacOS/PlushBuddy Station"
cp "$CARGO_TARGET_DIR/release/plushpal-desktop-host" "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
LLAMA_DYLIB=$(find "$CARGO_TARGET_DIR/release/build" -path '*/out/native/libplushpal_llama.dylib' -print | head -n 1)
test -n "$LLAMA_DYLIB"
cp "$LLAMA_DYLIB" "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
mkdir -p "$STATION_APP/Contents/Resources/voice"
cp tools/voice/chatterbox_tts.py "$STATION_APP/Contents/Resources/voice/chatterbox_tts.py"
cp tools/voice/luxtts_tts.py "$STATION_APP/Contents/Resources/voice/luxtts_tts.py"
cp tools/voice/luxtts_worker.py "$STATION_APP/Contents/Resources/voice/luxtts_worker.py"
cp packaging/macos/install_chatterbox_runtime.sh "$STATION_APP/Contents/Resources/install_chatterbox_runtime.sh"
cp packaging/macos/install_luxtts_runtime.sh "$STATION_APP/Contents/Resources/install_luxtts_runtime.sh"
mkdir -p "$STATION_APP/Contents/Resources/third_party"
if [ ! -f "$LUXTTS_SOURCE_DIR/requirements.txt" ]; then
  echo "LuxTTS source was not found at $LUXTTS_SOURCE_DIR." >&2
  echo "Run make public-artifacts, or set PLUSHPAL_LUXTTS_SOURCE_DIR to a LuxTTS checkout." >&2
  exit 4
fi
rsync -a --delete "$LUXTTS_SOURCE_DIR/" "$STATION_APP/Contents/Resources/third_party/LuxTTS/"
cp -R "$CLIENT_APP" "$STATION_APP/Contents/Resources/PlushBuddy.app"
PYTHON_RUNTIME_DIR=${PLUSHPAL_PYTHON_RUNTIME_DIR:-"$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python"}
if [ -d "$PYTHON_RUNTIME_DIR" ] && [ -x "$PYTHON_RUNTIME_DIR/bin/python3" ]; then
  "$PYTHON_RUNTIME_DIR/bin/python3" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)'
  rsync -a --delete "$PYTHON_RUNTIME_DIR/" "$STATION_APP/Contents/Resources/python/"
  find "$STATION_APP/Contents/Resources/python" -type l | while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
      /*)
        sibling="$(dirname "$link")/$(basename "$target")"
        if [ -e "$sibling" ]; then
          rm "$link"
          ln -s "$(basename "$target")" "$link"
        else
          rm "$link"
        fi
        ;;
    esac
  done
  "$STATION_APP/Contents/Resources/python/bin/python3" -m pip install --upgrade pip wheel setuptools
  "$STATION_APP/Contents/Resources/python/bin/python3" -m pip install "numpy>=1.26.0"
  "$STATION_APP/Contents/Resources/python/bin/python3" -m pip install -r "$STATION_APP/Contents/Resources/third_party/LuxTTS/requirements.txt"
  "$STATION_APP/Contents/Resources/python/bin/python3" -m pip install "setuptools<81"
  mkdir -p "$BUILD_ROOT/python-cache/numba"
  BUNDLED_HF_HOME="$STATION_APP/Contents/Resources/model-cache/huggingface"
  BUNDLED_HF_HUB="$BUNDLED_HF_HOME/hub"
  mkdir -p "$BUNDLED_HF_HUB"
  copy_hf_model_cache() {
    source_dir=$1
    destination_name=$2
    if [ -d "$source_dir/snapshots" ] && [ -d "$source_dir/blobs" ]; then
      mkdir -p "$BUNDLED_HF_HUB/$destination_name"
      rsync -a --delete "$source_dir/" "$BUNDLED_HF_HUB/$destination_name/"
      return 0
    fi
    return 1
  }
  LUXTTS_CACHE_SOURCE=${PLUSHPAL_LUXTTS_HF_CACHE_SOURCE:-"$HOME/.cache/huggingface/hub/models--YatharthS--LuxTTS"}
  WHISPER_CACHE_SOURCE=${PLUSHPAL_WHISPER_HF_CACHE_SOURCE:-"$HOME/.cache/huggingface/hub/models--openai--whisper-base"}
  MODEL_CACHE_SEEDED=0
  if copy_hf_model_cache "$LUXTTS_CACHE_SOURCE" "models--YatharthS--LuxTTS" &&
    copy_hf_model_cache "$WHISPER_CACHE_SOURCE" "models--openai--whisper-base"; then
    MODEL_CACHE_SEEDED=1
  fi
  if [ "$MODEL_CACHE_SEEDED" -eq 1 ]; then
    PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
      NUMBA_CACHE_DIR="$BUILD_ROOT/python-cache/numba" \
      HF_HOME="$BUNDLED_HF_HOME" \
      HF_HUB_OFFLINE=1 \
      TRANSFORMERS_OFFLINE=1 \
      HF_HUB_DISABLE_TELEMETRY=1 \
      "$STATION_APP/Contents/Resources/python/bin/python3" \
      "$STATION_APP/Contents/Resources/voice/luxtts_tts.py" \
      --healthcheck
  else
    PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
      NUMBA_CACHE_DIR="$BUILD_ROOT/python-cache/numba" \
      HF_HOME="$BUNDLED_HF_HOME" \
      HF_HUB_DISABLE_TELEMETRY=1 \
      "$STATION_APP/Contents/Resources/python/bin/python3" \
      "$STATION_APP/Contents/Resources/voice/luxtts_tts.py" \
      --healthcheck
  fi
else
  echo "warning: no bundled Python 3.12 runtime found; app setup will require Python 3.12 on the user's Mac." >&2
fi
sed "s/@VERSION@/$VERSION/g" packaging/macos/StationInfo.plist.in > "$STATION_APP/Contents/Info.plist"

TEAM_ID=${PLUSHPAL_TEAM_ID:-LOCAL}
ENTITLEMENTS="$OUTPUT/PlushBuddyStation.entitlements"
sed "s/@TEAM_ID@/$TEAM_ID/g" packaging/macos/PlushBuddyStation.entitlements.in > "$ENTITLEMENTS"

find "$CLIENT_APP" "$STATION_APP" -type l -exec touch -h -t "$ARCHIVE_TIMESTAMP" {} +
find "$CLIENT_APP" "$STATION_APP" ! -type l -exec touch -t "$ARCHIVE_TIMESTAMP" {} +

if [ -n "${PLUSHPAL_CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$PLUSHPAL_CODESIGN_IDENTITY" \
    "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
  codesign --force --options runtime --timestamp \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$CLIENT_APP"
  codesign --force --options runtime --timestamp \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP/Contents/Resources/PlushBuddy.app"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP"
else
  codesign --force --sign - "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
  codesign --force --sign - "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
  codesign --force --sign - "$CLIENT_APP"
  codesign --force --sign - "$STATION_APP/Contents/Resources/PlushBuddy.app"
  codesign --force --sign - "$STATION_APP"
fi

rm -f "$OUTPUT/PlushBuddy-$VERSION-macos.zip"
(cd "$OUTPUT" && COPYFILE_DISABLE=1 zip -X -q -y -r "PlushBuddy-$VERSION-macos.zip" "PlushBuddy Station.app" PlushBuddy.app)

if command -v hdiutil >/dev/null 2>&1; then
  DMG_ROOT="$OUTPUT/dmg-root"
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  cp -R "$STATION_APP" "$DMG_ROOT/PlushBuddy Station.app"
  cp -R "$CLIENT_APP" "$DMG_ROOT/PlushBuddy.app"
  rm -f "$OUTPUT/PlushBuddy-$VERSION-macos.dmg"
  hdiutil create -quiet -volname "PlushBuddy" -srcfolder "$DMG_ROOT" \
    -ov -format UDZO "$OUTPUT/PlushBuddy-$VERSION-macos.dmg"
  rm -rf "$DMG_ROOT"
fi
