#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plushpal-release-bundle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ARTIFACTS="$TMP/artifacts"
RELEASE="$TMP/release"
mkdir -p "$ARTIFACTS/macos" "$ARTIFACTS/android" "$ARTIFACTS/ios/PlushBuddy-iPhoneSimulator.app"

printf 'fake mac zip\n' > "$ARTIFACTS/macos/PlushBuddy-0.1.0-macos.zip"
printf 'fake apk\n' > "$ARTIFACTS/android/PlushBuddy-debug.apk"
printf 'fake ios app\n' > "$ARTIFACTS/ios/PlushBuddy-iPhoneSimulator.app/Info.plist"

PLUSHPAL_ARTIFACTS_DIR="$ARTIFACTS" \
PLUSHPAL_RELEASE_DIR="$RELEASE" \
PLUSHPAL_VERSION="test-release" \
  sh "$ROOT/packaging/create-release-bundle.sh" > "$TMP/output.log"

BUNDLE="$RELEASE/test-release"
test -f "$BUNDLE/PlushBuddy-0.1.0-macos.zip"
test -f "$BUNDLE/PlushBuddy-debug.apk"
test -f "$BUNDLE/PlushBuddy-iPhoneSimulator-test-release.zip"
test -s "$BUNDLE/RELEASE_NOTES.md"
test -s "$BUNDLE/SHA256SUMS"

(cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS >/dev/null)

echo "PASS: release bundle structure and checksums"
