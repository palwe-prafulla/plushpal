#!/bin/sh
set -eu

VENV_DIR=${1:?usage: install_luxtts_runtime.sh /path/to/venv}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOURCES_DIR="$SCRIPT_DIR"
LUX_REQUIREMENTS="$RESOURCES_DIR/third_party/LuxTTS/requirements.txt"
LUX_SCRIPT="${PLUSHPAL_LUXTTS_SCRIPT:-$RESOURCES_DIR/voice/luxtts_tts.py}"
RUNTIME_MARKER="$VENV_DIR/.plushbuddy-luxtts-runtime.env"
INSTALLER_VERSION="2026-06-26-luxtts-runtime-v1"

mkdir -p "$(dirname "$VENV_DIR")"

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
  [ "$(marker_value requirements_sha256)" = "$(sha256_file "$LUX_REQUIREMENTS")" ] || return 1
  [ "$(marker_value script_sha256)" = "$(sha256_file "$LUX_SCRIPT")" ] || return 1
}

write_runtime_marker() {
  {
    echo "schema_version=1"
    echo "installer_version=$INSTALLER_VERSION"
    echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "python_path=$VENV_DIR/bin/python"
    echo "python_version=$("$VENV_DIR/bin/python" --version 2>&1 | sed 's/[^A-Za-z0-9._ -]/_/g')"
    echo "requirements_sha256=$(sha256_file "$LUX_REQUIREMENTS")"
    echo "script_sha256=$(sha256_file "$LUX_SCRIPT")"
  } >"$RUNTIME_MARKER"
}

if [ -x "$VENV_DIR/bin/python" ]; then
  if runtime_marker_is_current &&
    python_is_supported "$VENV_DIR/bin/python" &&
    "$VENV_DIR/bin/python" "$LUX_SCRIPT" --healthcheck >/dev/null 2>&1; then
    echo "LuxTTS voice runtime already installed."
    exit 0
  fi
  echo "Existing LuxTTS runtime is incomplete or stale. Repairing..."
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
  echo "Python 3.10 or newer is required to install LuxTTS voice support." >&2
  echo "Install Python 3.10+, then click Retry setup." >&2
  exit 2
fi

if [ ! -f "$LUX_REQUIREMENTS" ]; then
  echo "LuxTTS requirements are missing from the app bundle." >&2
  exit 3
fi

echo "Using $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN"
echo "Creating LuxTTS environment..."
"$PYTHON_BIN" -m venv "$VENV_DIR"

echo "Updating packaging tools..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools

echo "Installing LuxTTS dependencies..."
"$VENV_DIR/bin/python" -m pip install -r "$LUX_REQUIREMENTS"

echo "Verifying LuxTTS runtime..."
"$VENV_DIR/bin/python" "$LUX_SCRIPT" --healthcheck

write_runtime_marker

echo "LuxTTS voice runtime is ready."
