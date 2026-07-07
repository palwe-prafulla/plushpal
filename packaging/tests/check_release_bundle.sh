#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/toytalk-release-bundle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ARTIFACTS="$TMP/artifacts"
RELEASE="$TMP/release"
mkdir -p "$ARTIFACTS/macos" "$ARTIFACTS/android" "$ARTIFACTS/ios/ToyTalk-iPhoneSimulator.app"

printf 'fake mac zip\n' > "$ARTIFACTS/macos/ToyTalk-v2-macos.zip"
printf 'fake apk\n' > "$ARTIFACTS/android/ToyTalk-debug.apk"
printf 'fake ios app\n' > "$ARTIFACTS/ios/ToyTalk-iPhoneSimulator.app/Info.plist"

PLUSHPAL_ARTIFACTS_DIR="$ARTIFACTS" \
PLUSHPAL_RELEASE_DIR="$RELEASE" \
PLUSHPAL_VERSION="test-release" \
  sh "$ROOT/packaging/create-release-bundle.sh" > "$TMP/output.log"

BUNDLE="$RELEASE/test-release"
test -f "$BUNDLE/ToyTalk-v2-macos.zip"
test -f "$BUNDLE/ToyTalk-debug.apk"
test -f "$BUNDLE/ToyTalk-iPhoneSimulator-test-release.zip"
test -s "$BUNDLE/RELEASE_NOTES.md"
test -s "$BUNDLE/SHA256SUMS"

(cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS >/dev/null)

echo "PASS: release bundle structure and checksums"
