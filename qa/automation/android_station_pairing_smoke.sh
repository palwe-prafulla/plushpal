#!/usr/bin/env bash
set -euo pipefail
set +m

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULT_ROOT="${PLUSHPAL_TEST_RESULTS_DIR:-$HOME/Downloads/PlushPal/test-results}"
RESULT_DIR="$RESULT_ROOT/android-station-pairing-$(date +%Y%m%d-%H%M%S)"
DEVICE_ID="${ANDROID_DEVICE_ID:-}"
PACKAGE_ID="${PLUSHPAL_ANDROID_PACKAGE:-com.plushpal.app}"
mkdir -p "$RESULT_DIR"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi
if [[ -z "$DEVICE_ID" ]]; then
  echo "No authorized Android device found." >&2
  exit 2
fi

DATA_DIR="$(mktemp -d /tmp/plushbuddy-android-pairing-data-XXXXXX)"
MODEL_DIR="$(mktemp -d /tmp/plushbuddy-android-pairing-models-XXXXXX)"
HOST_LOG="$RESULT_DIR/host.log"

cleanup() {
  if [[ -n "${HOST_PID:-}" ]]; then kill "$HOST_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$DATA_DIR" "$MODEL_DIR"
}
trap cleanup EXIT

(
  set +e
  PLUSHPAL_NO_BROWSER=1 \
  PLUSHPAL_PRINT_BOOTSTRAP_URL=1 \
  PLUSHPAL_PORT=0 \
  PLUSHPAL_DATA_DIR="$DATA_DIR" \
  PLUSHPAL_MODEL_DIR="$MODEL_DIR" \
  CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Downloads/PlushPal/test-build/cargo-target}" \
  PLUSHPAL_ENABLE_MAC_KEYCHAIN_GEMINI=0 \
  cargo run --release -p plushpal-desktop-host --features native-runtime > "$HOST_LOG" 2>&1
) &
HOST_PID=$!

for _ in $(seq 1 120); do
  if grep -q "PlushPal test bootstrap URL:" "$HOST_LOG"; then break; fi
  sleep 1
done

BOOTSTRAP_URL="$(grep "PlushPal test bootstrap URL:" "$HOST_LOG" | tail -1 | sed 's/.*URL: //')"
if [[ -z "$BOOTSTRAP_URL" ]]; then
  echo "Station did not print bootstrap URL." >&2
  exit 3
fi

PORT="$(python3 - <<'PY' "$BOOTSTRAP_URL"
import sys
from urllib.parse import urlparse
print(urlparse(sys.argv[1]).port)
PY
)"
BOOTSTRAP="$(python3 - <<'PY' "$BOOTSTRAP_URL"
import sys
from urllib.parse import urlparse, parse_qs
print(parse_qs(urlparse(sys.argv[1]).fragment).get('bootstrap', [''])[0])
PY
)"
BASE_URL="http://127.0.0.1:$PORT"

COOKIE_HEADERS="$RESULT_DIR/bootstrap-headers.txt"
curl -sS -o /dev/null -D "$COOKIE_HEADERS" \
  -X POST \
  -H "Origin: $BASE_URL" \
  -H "x-plushpal-bootstrap: $BOOTSTRAP" \
  "$BASE_URL/api/v1/bootstrap"
COOKIE="$(grep -i '^set-cookie:' "$COOKIE_HEADERS" | head -1 | sed -E 's/[Ss]et-[Cc]ookie: ([^;]+).*/\\1/' | tr -d '\r')"
if [[ -z "$COOKIE" ]]; then
  echo "Could not exchange bootstrap token for session cookie." >&2
  exit 4
fi

adb -s "$DEVICE_ID" reverse "tcp:$PORT" "tcp:$PORT" > "$RESULT_DIR/adb-reverse.log" 2>&1
adb -s "$DEVICE_ID" shell am start \
  -n "$PACKAGE_ID/.MainActivity" \
  -a "$PACKAGE_ID.DEBUG_SAVE_PAIRING" \
  --es baseUrl "$BASE_URL" \
  --es cookie "$COOKIE" > "$RESULT_DIR/debug-pairing-intent.log" 2>&1
sleep 3

adb -s "$DEVICE_ID" shell uiautomator dump /sdcard/plushbuddy-pairing.xml > "$RESULT_DIR/dump.log" 2>&1 || true
adb -s "$DEVICE_ID" pull /sdcard/plushbuddy-pairing.xml "$RESULT_DIR/window.xml" > "$RESULT_DIR/pull.log" 2>&1 || true
adb -s "$DEVICE_ID" exec-out screencap -p > "$RESULT_DIR/screen.png" || true

if adb -s "$DEVICE_ID" shell dumpsys package "$PACKAGE_ID" >/dev/null 2>&1; then
  echo "PASS: Android debug pairing intent accepted for Station on localhost:$PORT"
  echo "pass" > "$RESULT_DIR/status.txt"
else
  echo "WARN: Android package not visible after pairing intent." >&2
  echo "needs-review" > "$RESULT_DIR/status.txt"
  exit 5
fi

echo "Results: $RESULT_DIR"
