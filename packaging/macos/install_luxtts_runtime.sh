#!/bin/sh
set -eu

VENV_DIR=${1:?usage: install_luxtts_runtime.sh /path/to/venv}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOURCES_DIR="$SCRIPT_DIR"
APP_SUPPORT_DIR=$(CDPATH= cd -- "$(dirname -- "$VENV_DIR")" && pwd)
LUX_SOURCE_DIR=${PLUSHPAL_LUXTTS_SOURCE_DIR:-"$APP_SUPPORT_DIR/deps/LuxTTS"}
LUX_REQUIREMENTS="$LUX_SOURCE_DIR/requirements.txt"
LUX_SCRIPT="${PLUSHPAL_LUXTTS_SCRIPT:-$RESOURCES_DIR/voice/luxtts_tts.py}"
RUNTIME_MARKER="$VENV_DIR/.plushbuddy-luxtts-runtime.env"
INSTALLER_VERSION="2026-07-05-luxtts-lazy-runtime-v2"
UV_DIR=${PLUSHPAL_UV_DIR:-"$APP_SUPPORT_DIR/tools/uv"}
UV_BIN="$UV_DIR/uv"

mkdir -p "$(dirname "$VENV_DIR")"

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

download_luxtts_source() {
  if [ -f "$LUX_REQUIREMENTS" ]; then
    return 0
  fi

  echo "Downloading LuxTTS source to $LUX_SOURCE_DIR..."
  rm -rf "$LUX_SOURCE_DIR.tmp" "$LUX_SOURCE_DIR"
  mkdir -p "$(dirname "$LUX_SOURCE_DIR")"

  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/ysharma3501/LuxTTS.git "$LUX_SOURCE_DIR.tmp"
    mv "$LUX_SOURCE_DIR.tmp" "$LUX_SOURCE_DIR"
    return 0
  fi

  if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    archive="$(dirname "$LUX_SOURCE_DIR")/luxtts-main.tar.gz"
    curl -L --fail --retry 3 --connect-timeout 20 \
      https://github.com/ysharma3501/LuxTTS/archive/refs/heads/main.tar.gz \
      -o "$archive"
    mkdir -p "$LUX_SOURCE_DIR.tmp"
    tar -xzf "$archive" -C "$LUX_SOURCE_DIR.tmp" --strip-components 1
    rm -f "$archive"
    mv "$LUX_SOURCE_DIR.tmp" "$LUX_SOURCE_DIR"
    return 0
  fi

  echo "Could not download LuxTTS source because neither git nor curl+tar is available." >&2
  return 4
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
    echo "luxtts_source_path=$LUX_SOURCE_DIR"
    echo "requirements_sha256=$(sha256_file "$LUX_REQUIREMENTS")"
    echo "script_sha256=$(sha256_file "$LUX_SCRIPT")"
  } >"$RUNTIME_MARKER"
}

download_luxtts_source

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
  echo "Installing managed Python 3.12 for PlushBuddy Hub..."
  "$UV_BIN" python install 3.12
fi

if [ ! -f "$LUX_REQUIREMENTS" ]; then
  echo "LuxTTS requirements are missing after download: $LUX_REQUIREMENTS" >&2
  exit 3
fi

echo "Using LuxTTS source at $LUX_SOURCE_DIR"
echo "Creating LuxTTS environment..."
if [ -n "$PYTHON_BIN" ]; then
  echo "Using $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
else
  echo "Using managed Python 3.12 via $UV_BIN"
  "$UV_BIN" venv --python 3.12 "$VENV_DIR"
fi

echo "Updating packaging tools..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools

echo "Installing LuxTTS dependencies..."
"$VENV_DIR/bin/python" -m pip install -r "$LUX_REQUIREMENTS"

echo "Verifying LuxTTS runtime..."
"$VENV_DIR/bin/python" "$LUX_SCRIPT" --healthcheck

write_runtime_marker

echo "LuxTTS voice runtime is ready."
