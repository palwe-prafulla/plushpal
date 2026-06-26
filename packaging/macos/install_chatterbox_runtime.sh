#!/bin/sh
set -eu

VENV_DIR=${1:?usage: install_chatterbox_runtime.sh /path/to/venv}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$(dirname "$VENV_DIR")"

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
}

if [ -x "$VENV_DIR/bin/python" ]; then
  if python_is_supported "$VENV_DIR/bin/python" &&
    "$VENV_DIR/bin/python" -c 'import torch, torchaudio; from chatterbox.tts import ChatterboxTTS' >/dev/null 2>&1; then
    echo "Local voice runtime already installed."
    exit 0
  fi
  echo "Existing local voice runtime is incomplete. Repairing..."
  rm -rf "$VENV_DIR"
fi

PYTHON_BIN=""
for CANDIDATE in \
  "${PLUSHPAL_BOOTSTRAP_PYTHON:-}" \
  "${PLUSHPAL_BUNDLED_PYTHON:-}" \
  "$SCRIPT_DIR/python/bin/python3" \
  "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3" \
  "/opt/homebrew/bin/python3.12" \
  "/usr/local/bin/python3.12" \
  "/opt/homebrew/bin/python3" \
  "/usr/local/bin/python3" \
  "$(command -v python3 2>/dev/null || true)"
do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ] && python_is_supported "$CANDIDATE"; then
    PYTHON_BIN="$CANDIDATE"
    break
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  echo "Python 3.12 or newer is required to install the local voice runtime." >&2
  echo "Install Python 3.12, then click Retry setup." >&2
  exit 2
fi

echo "Using $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN"

echo "Creating local voice environment..."
"$PYTHON_BIN" -m venv "$VENV_DIR"

echo "Updating packaging tools..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools

echo "Installing voice dependencies..."
"$VENV_DIR/bin/python" -m pip install "numpy>=1.26.0"
"$VENV_DIR/bin/python" -m pip install "chatterbox-tts==0.1.7"
"$VENV_DIR/bin/python" -m pip install "setuptools<81"

echo "Verifying local voice runtime..."
"$VENV_DIR/bin/python" -c 'import torch, torchaudio; from chatterbox.tts import ChatterboxTTS'

echo "Local voice runtime is ready."
