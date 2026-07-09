#!/bin/sh
set -eu

VENV_DIR=${1:?usage: install_search_router_runtime.sh /path/to/venv}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOURCES_DIR="$SCRIPT_DIR"
APP_SUPPORT_DIR=$(CDPATH= cd -- "$(dirname -- "$VENV_DIR")" && pwd)
ROUTER_SCRIPT="${PLUSHPAL_SEARCH_ROUTER_SCRIPT:-$RESOURCES_DIR/search/search_router_worker.py}"
ROUTER_MODEL="${PLUSHPAL_SEARCH_ROUTER_MODEL:-sentence-transformers/all-MiniLM-L6-v2}"
RUNTIME_MARKER="$VENV_DIR/.toytalk-search-router-runtime.env"
INSTALLER_VERSION="2026-07-07-minilm-l6-router-v1"
UV_DIR=${PLUSHPAL_UV_DIR:-"$APP_SUPPORT_DIR/tools/uv"}
UV_BIN="$UV_DIR/uv"
HF_HOME_DIR=${PLUSHPAL_SEARCH_ROUTER_HF_HOME:-"$APP_SUPPORT_DIR/search-router-runtime/huggingface"}

mkdir -p "$(dirname "$VENV_DIR")" "$HF_HOME_DIR"

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

marker_value() {
  sed -n "s/^$1=//p" "$RUNTIME_MARKER" | head -n 1
}

runtime_marker_is_current() {
  [ -f "$RUNTIME_MARKER" ] || return 1
  [ "$(marker_value installer_version)" = "$INSTALLER_VERSION" ] || return 1
  [ "$(marker_value script_sha256)" = "$(sha256_file "$ROUTER_SCRIPT")" ] || return 1
  [ "$(marker_value model)" = "$ROUTER_MODEL" ] || return 1
}

write_runtime_marker() {
  {
    echo "schema_version=1"
    echo "installer_version=$INSTALLER_VERSION"
    echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "python_path=$VENV_DIR/bin/python"
    echo "python_version=$("$VENV_DIR/bin/python" --version 2>&1 | sed 's/[^A-Za-z0-9._ -]/_/g')"
    echo "script_sha256=$(sha256_file "$ROUTER_SCRIPT")"
    echo "model=$ROUTER_MODEL"
    echo "hf_home=$HF_HOME_DIR"
  } >"$RUNTIME_MARKER"
}

if [ ! -f "$ROUTER_SCRIPT" ]; then
  echo "ToyTalk search router script is missing: $ROUTER_SCRIPT" >&2
  exit 3
fi

if [ -x "$VENV_DIR/bin/python" ]; then
  if runtime_marker_is_current &&
    python_is_supported "$VENV_DIR/bin/python" &&
    HF_HOME="$HF_HOME_DIR" HF_HUB_CACHE="$HF_HOME_DIR/hub" TRANSFORMERS_CACHE="$HF_HOME_DIR/hub" \
      "$VENV_DIR/bin/python" "$ROUTER_SCRIPT" --model "$ROUTER_MODEL" --healthcheck >/dev/null 2>&1; then
    echo "Search router runtime already installed."
    exit 0
  fi
  echo "Existing search router runtime is incomplete or stale. Repairing..."
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
  echo "Python 3.10+ was not found. Installing a local Python bootstrapper..."
  if [ ! -x "$UV_BIN" ]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to download the local Python bootstrapper." >&2
      exit 2
    fi
    mkdir -p "$UV_DIR"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$UV_DIR" sh
  fi
  if [ ! -x "$UV_BIN" ]; then
    echo "Could not install the local Python bootstrapper." >&2
    exit 2
  fi
  echo "Installing managed Python 3.12 for ToyTalk Hub..."
  "$UV_BIN" python install 3.12
fi

echo "Creating search router environment..."
if [ -n "$PYTHON_BIN" ]; then
  echo "Using $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
else
  echo "Using managed Python 3.12 via $UV_BIN"
  "$UV_BIN" venv --python 3.12 "$VENV_DIR"
fi

echo "Updating packaging tools..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools

echo "Installing search router dependencies..."
"$VENV_DIR/bin/python" -m pip install \
  "sentence-transformers>=3,<6" \
  "scikit-learn>=1.4,<2" \
  "numpy>=1.24" \
  "torch>=2.3" \
  "transformers>=4.41,<5"

echo "Downloading and verifying search router model..."
HF_HOME="$HF_HOME_DIR" HF_HUB_CACHE="$HF_HOME_DIR/hub" TRANSFORMERS_CACHE="$HF_HOME_DIR/hub" \
  "$VENV_DIR/bin/python" "$ROUTER_SCRIPT" --model "$ROUTER_MODEL" --healthcheck

write_runtime_marker

echo "Search router runtime is ready."
