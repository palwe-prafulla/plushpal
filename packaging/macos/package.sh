#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=${PLUSHPAL_VERSION:-}
if [ -z "$VERSION" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)
  else
    VERSION="local"
  fi
fi
ARCHIVE_TIMESTAMP=${PLUSHPAL_ARCHIVE_TIMESTAMP:-202601010000}
ARTIFACTS_ROOT=${PLUSHPAL_ARTIFACTS_DIR:-"$ROOT/dist"}
BUILD_ROOT=${PLUSHPAL_BUILD_DIR:-"$ROOT/build"}
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/target"}
OUTPUT="$ARTIFACTS_ROOT/macos"
STATION_APP="$OUTPUT/ToyTalk Hub.app"
CLIENT_APP="$OUTPUT/ToyTalk.app"
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

rm -rf "$STATION_APP" "$CLIENT_APP" "$OUTPUT/ToyTalk.app"
mkdir -p "$OUTPUT" "$BUILD_ROOT"

mkdir -p "$CLIENT_APP/Contents/MacOS" "$CLIENT_APP/Contents/Resources"
swiftc -O \
  -framework AppKit \
  -framework WebKit \
  apps/macos/client_app/AppShell.swift \
  -o "$CLIENT_APP/Contents/MacOS/ToyTalk"
sed "s/@VERSION@/$VERSION/g" packaging/macos/ClientInfo.plist.in > "$CLIENT_APP/Contents/Info.plist"

mkdir -p "$STATION_APP/Contents/MacOS" "$STATION_APP/Contents/Resources" "$STATION_APP/Contents/Frameworks"
swiftc -O \
  -framework AppKit \
  -framework CoreImage \
  -framework Security \
  -framework WebKit \
  apps/macos/station_app/AppShell.swift \
  -o "$STATION_APP/Contents/MacOS/ToyTalk Hub"
cp "$CARGO_TARGET_DIR/release/plushpal-desktop-host" "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
LLAMA_DYLIB=$(find "$CARGO_TARGET_DIR/release/build" -path '*/out/native/libplushpal_llama.dylib' -print | head -n 1)
test -n "$LLAMA_DYLIB"
cp "$LLAMA_DYLIB" "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
mkdir -p "$STATION_APP/Contents/Resources/voice"
mkdir -p "$STATION_APP/Contents/Resources/stt"
cp tools/voice/chatterbox_tts.py "$STATION_APP/Contents/Resources/voice/chatterbox_tts.py"
cp tools/voice/luxtts_tts.py "$STATION_APP/Contents/Resources/voice/luxtts_tts.py"
cp tools/voice/luxtts_worker.py "$STATION_APP/Contents/Resources/voice/luxtts_worker.py"
cp tools/stt/whisper_transcribe.py "$STATION_APP/Contents/Resources/stt/whisper_transcribe.py"
chmod +x "$STATION_APP/Contents/Resources/stt/whisper_transcribe.py"
cp packaging/macos/install_chatterbox_runtime.sh "$STATION_APP/Contents/Resources/install_chatterbox_runtime.sh"
cp packaging/macos/install_luxtts_runtime.sh "$STATION_APP/Contents/Resources/install_luxtts_runtime.sh"
cp -R "$CLIENT_APP" "$STATION_APP/Contents/Resources/ToyTalk.app"
echo "Building a thin Hub bundle: LuxTTS source, Python dependencies, Hugging Face caches, and local AI models are prepared lazily in user application support."
sed "s/@VERSION@/$VERSION/g" packaging/macos/StationInfo.plist.in > "$STATION_APP/Contents/Info.plist"

TEAM_ID=${PLUSHPAL_TEAM_ID:-LOCAL}
STATION_ENTITLEMENTS="$OUTPUT/ToyTalkStation.entitlements"
CLIENT_ENTITLEMENTS="$OUTPUT/ToyTalk.entitlements"
sed "s/@TEAM_ID@/$TEAM_ID/g" packaging/macos/PlushBuddyStation.entitlements.in > "$STATION_ENTITLEMENTS"
sed "s/@TEAM_ID@/$TEAM_ID/g" packaging/macos/PlushPal.entitlements.in > "$CLIENT_ENTITLEMENTS"

find "$CLIENT_APP" "$STATION_APP" -type l -exec touch -h -t "$ARCHIVE_TIMESTAMP" {} +
find "$CLIENT_APP" "$STATION_APP" ! -type l -exec touch -t "$ARCHIVE_TIMESTAMP" {} +

if [ -n "${PLUSHPAL_CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$PLUSHPAL_CODESIGN_IDENTITY" \
    "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
  codesign --force --options runtime --timestamp --entitlements "$STATION_ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
  codesign --force --options runtime --timestamp --entitlements "$CLIENT_ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$CLIENT_APP"
  codesign --force --options runtime --timestamp --entitlements "$CLIENT_ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP/Contents/Resources/ToyTalk.app"
  codesign --force --options runtime --timestamp --entitlements "$STATION_ENTITLEMENTS" \
    --sign "$PLUSHPAL_CODESIGN_IDENTITY" "$STATION_APP"
else
  codesign --force --sign - "$STATION_APP/Contents/Frameworks/libplushpal_llama.dylib"
  codesign --force --sign - "$STATION_APP/Contents/MacOS/plushpal-desktop-host"
  codesign --force --sign - "$CLIENT_APP"
  codesign --force --sign - "$STATION_APP/Contents/Resources/ToyTalk.app"
  codesign --force --sign - "$STATION_APP"
fi

rm -f "$OUTPUT"/ToyTalk-*-macos.zip "$OUTPUT"/ToyTalk-*-macos.dmg
(cd "$OUTPUT" && COPYFILE_DISABLE=1 zip -X -q -y -r "ToyTalk-$VERSION-macos.zip" "ToyTalk Hub.app" ToyTalk.app)

if command -v hdiutil >/dev/null 2>&1; then
  DMG_ROOT="$OUTPUT/dmg-root"
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  cp -R "$STATION_APP" "$DMG_ROOT/ToyTalk Hub.app"
  cp -R "$CLIENT_APP" "$DMG_ROOT/ToyTalk.app"
  rm -f "$OUTPUT/ToyTalk-$VERSION-macos.dmg"
  hdiutil create -quiet -volname "ToyTalk" -srcfolder "$DMG_ROOT" \
    -ov -format UDZO "$OUTPUT/ToyTalk-$VERSION-macos.dmg"
  rm -rf "$DMG_ROOT"
fi
