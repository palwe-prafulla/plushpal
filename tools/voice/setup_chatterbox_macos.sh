#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
DEPS_ROOT="${PLUSHPAL_DEPS_DIR:-$PUBLIC_ROOT/deps}"
VENV_DIR="${PLUSHPAL_CHATTERBOX_VENV:-"$DEPS_ROOT/.venv-chatterbox"}"
BUNDLED_CODEX_PYTHON="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
if [ -n "${PYTHON:-}" ]; then
  PYTHON_BIN="$PYTHON"
elif [ -x "$BUNDLED_CODEX_PYTHON" ]; then
  PYTHON_BIN="$BUNDLED_CODEX_PYTHON"
else
  PYTHON_BIN="python3"
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools
"$VENV_DIR/bin/python" -m pip install "numpy>=1.26.0"
"$VENV_DIR/bin/python" -m pip install chatterbox-tts
"$VENV_DIR/bin/python" -m pip install "setuptools<81"

cat <<EOF
Chatterbox local voice runtime installed.

Run PlushPal with:

  PLUSHPAL_VOICE_ENGINE=chatterbox \\
  PLUSHPAL_CHATTERBOX_PYTHON="$VENV_DIR/bin/python" \\
  PLUSHPAL_CHATTERBOX_SCRIPT="$ROOT_DIR/tools/voice/chatterbox_tts.py" \\
  PLUSHPAL_CHATTERBOX_ENGINE=standard \\
  cargo run --release -p plushpal-desktop-host --features native-runtime

Notes:
- First synthesis may download Chatterbox model weights into your local Hugging Face cache.
- Uploaded/reference voice samples are still kept local by PlushPal.
- Use PLUSHPAL_CHATTERBOX_ENGINE=turbo if you prefer lower latency over maximum quality.
EOF
