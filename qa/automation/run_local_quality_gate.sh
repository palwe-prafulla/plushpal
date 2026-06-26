#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
RESULT_ROOT="${PLUSHPAL_TEST_RESULTS_DIR:-$PUBLIC_ROOT/test-results}"
RESULT_DIR="$RESULT_ROOT/local-quality-$(date +%Y%m%d-%H%M%S)"
WORKTREE="${PLUSHPAL_TEST_WORKTREE:-$PUBLIC_ROOT/test-workspaces/local-quality-source}"
mkdir -p "$RESULT_DIR"

rm -rf "$WORKTREE"
mkdir -p "$WORKTREE"
rsync -a --delete "$ROOT_DIR/" "$WORKTREE/" \
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

export CARGO_TARGET_DIR="$PUBLIC_ROOT/test-build/cargo-target"

run_step() {
  local name="$1"
  shift
  echo "==> $name"
  (cd "$WORKTREE" && "$@") > "$RESULT_DIR/$name.log" 2>&1
}

run_step cargo-test cargo test --workspace
run_step public-repo-check make public-repo-check
run_step doctor make doctor
run_step flutter-analyze bash -lc "cd apps/android/flutter_app && flutter analyze"
run_step flutter-test bash -lc "cd apps/android/flutter_app && flutter test"
run_step web-node-tests bash -lc "cd apps/android/flutter_app && node --test test/audio_normalization_test.js test/plushpal_backend_web_test.mjs"
run_step product-layout make test-product-layout

echo "PASS: local quality gate completed."
echo "Results: $RESULT_DIR"
echo "Test workspace: $WORKTREE"
