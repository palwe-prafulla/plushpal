#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/toytalk-github-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

RELEASE_DIR="$TMP/release"
mkdir -p "$RELEASE_DIR"
printf '# Test release\n' > "$RELEASE_DIR/RELEASE_NOTES.md"
printf 'artifact\n' > "$RELEASE_DIR/ToyTalk-test.zip"
(cd "$RELEASE_DIR" && shasum -a 256 RELEASE_NOTES.md ToyTalk-test.zip > SHA256SUMS)

"$ROOT/tools/github/create_release.py" palwe-prafulla toytalk v0.0.0-test "$RELEASE_DIR" --dry-run \
  > "$TMP/output.log"

grep -F 'DRY_RUN release palwe-prafulla/toytalk tag=v0.0.0-test' "$TMP/output.log" >/dev/null
grep -F 'DRY_RUN upload SHA256SUMS' "$TMP/output.log" >/dev/null
grep -F 'DRY_RUN upload ToyTalk-test.zip' "$TMP/output.log" >/dev/null

echo "PASS: GitHub release dry run"
