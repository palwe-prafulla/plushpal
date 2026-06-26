#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
DEPS_ROOT="${PLUSHPAL_DEPS_DIR:-$PUBLIC_ROOT/deps}"
LUXTTS_SOURCE_DIR="${PLUSHPAL_LUXTTS_SOURCE_DIR:-$DEPS_ROOT/LuxTTS}"
VENV="${PLUSHPAL_LUXTTS_VENV:-$DEPS_ROOT/.venv-luxtts}"
PYTHON="${PYTHON:-python3}"

if [ ! -f "$LUXTTS_SOURCE_DIR/requirements.txt" ]; then
  mkdir -p "$DEPS_ROOT"
  git clone --depth 1 https://github.com/ysharma3501/LuxTTS.git "$LUXTTS_SOURCE_DIR"
fi

if [ ! -d "$VENV" ]; then
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
"$VENV/bin/python" -m pip install -r "$LUXTTS_SOURCE_DIR/requirements.txt"
"$VENV/bin/python" "$ROOT/tools/voice/luxtts_tts.py" --healthcheck

echo "LuxTTS runtime is ready at $VENV"
