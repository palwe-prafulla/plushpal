#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PUBLIC_ROOT=${PLUSHPAL_PUBLIC_ROOT:-"$HOME/Downloads/PlushPal"}
ARTIFACTS_ROOT=${PLUSHPAL_ARTIFACTS_DIR:-"$PUBLIC_ROOT/artifacts"}
RELEASE_ROOT=${PLUSHPAL_RELEASE_DIR:-"$PUBLIC_ROOT/release"}
VERSION=${PLUSHPAL_VERSION:-}

if [ -z "$VERSION" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)
  else
    VERSION="local"
  fi
fi

safe_version=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')
DEST="$RELEASE_ROOT/$safe_version"

if [ ! -d "$ARTIFACTS_ROOT" ]; then
  echo "Artifacts directory not found: $ARTIFACTS_ROOT" >&2
  echo "Run make public-artifacts first, or set PLUSHPAL_ARTIFACTS_DIR." >&2
  exit 2
fi

rm -rf "$DEST"
mkdir -p "$DEST"

copy_if_present() {
  for path in "$@"; do
    [ -e "$path" ] || continue
    cp -R "$path" "$DEST/"
  done
}

zip_app_if_present() {
  app_path=$1
  zip_name=$2
  [ -d "$app_path" ] || return 0
  if command -v ditto >/dev/null 2>&1; then
    (cd "$(dirname "$app_path")" && ditto -c -k --keepParent "$(basename "$app_path")" "$DEST/$zip_name")
  else
    (cd "$(dirname "$app_path")" && zip -qry "$DEST/$zip_name" "$(basename "$app_path")")
  fi
}

copy_if_present "$ARTIFACTS_ROOT"/macos/*.zip "$ARTIFACTS_ROOT"/macos/*.dmg
copy_if_present "$ARTIFACTS_ROOT"/android/*.apk
zip_app_if_present "$ARTIFACTS_ROOT/ios/PlushBuddy-iPhoneSimulator.app" "PlushBuddy-iPhoneSimulator-$safe_version.zip"
zip_app_if_present "$ARTIFACTS_ROOT/ios/PlushBuddy-iPhoneOS-unsigned.app" "PlushBuddy-iPhoneOS-unsigned-$safe_version.zip"

cat > "$DEST/RELEASE_NOTES.md" <<EOF
# PlushBuddy $VERSION

Local release bundle generated from this checkout.

## Contents

- macOS Station and Mac client archives, when macOS packaging was built
- Android debug APK, when Android tooling was available
- iPhone simulator / unsigned device app archives, when Xcode tooling was available
- SHA256SUMS for all bundled artifacts

## Notes

- Unsigned/development artifacts are for local testing and learning.
- LuxTTS model caches are not bundled; Station prepares local runtime/cache on first use.
- Do not upload private voice samples, API keys, or local databases to releases.
EOF

(
  cd "$DEST"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -print | sort | sed 's#^\./##' |
    while IFS= read -r file; do
      shasum -a 256 "$file"
    done
) > "$DEST/SHA256SUMS"

if [ ! -s "$DEST/SHA256SUMS" ]; then
  echo "Release bundle contains no distributable artifacts under $ARTIFACTS_ROOT." >&2
  exit 3
fi

echo "Release bundle ready: $DEST"
echo "Checksums: $DEST/SHA256SUMS"
