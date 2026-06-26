#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
RESULT_ROOT="${PLUSHPAL_TEST_RESULTS_DIR:-$HOME/Downloads/PlushPal/test-results}"
RESULT_DIR="$RESULT_ROOT/android-device-$(date +%Y%m%d-%H%M%S)"
DEVICE_ID="${ANDROID_DEVICE_ID:-}"
PACKAGE_ID="${PLUSHPAL_ANDROID_PACKAGE:-com.plushpal.app}"
APK="${PLUSHPAL_ANDROID_APK:-$PUBLIC_ROOT/artifacts/android/PlushBuddy-debug.apk}"

mkdir -p "$RESULT_DIR"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No authorized Android device found. Connect a device with USB debugging enabled." >&2
  exit 2
fi

echo "Using Android device: $DEVICE_ID"
flutter devices > "$RESULT_DIR/flutter-devices.txt"
adb -s "$DEVICE_ID" devices -l > "$RESULT_DIR/adb-devices.txt"

if [[ ! -f "$APK" ]]; then
  echo "APK not found at $APK. Run 'make public-artifacts' first, or set PLUSHPAL_ANDROID_APK." >&2
  exit 3
fi

echo "Installing APK..."
adb -s "$DEVICE_ID" install -r "$APK" > "$RESULT_DIR/adb-install.log" 2>&1

echo "Clearing app data for fresh-launch smoke..."
adb -s "$DEVICE_ID" shell pm clear "$PACKAGE_ID" > "$RESULT_DIR/pm-clear.log" 2>&1 || true

echo "Launching PlushBuddy..."
adb -s "$DEVICE_ID" shell monkey -p "$PACKAGE_ID" -c android.intent.category.LAUNCHER 1 \
  > "$RESULT_DIR/launch.log" 2>&1
sleep 5

echo "Capturing UI dump and screenshot..."
adb -s "$DEVICE_ID" shell uiautomator dump /sdcard/plushbuddy-window.xml \
  > "$RESULT_DIR/uiautomator-dump.log" 2>&1 || true
adb -s "$DEVICE_ID" pull /sdcard/plushbuddy-window.xml "$RESULT_DIR/window.xml" \
  > "$RESULT_DIR/uiautomator-pull.log" 2>&1 || true
adb -s "$DEVICE_ID" exec-out screencap -p > "$RESULT_DIR/launch.png" || true

if [[ -f "$RESULT_DIR/window.xml" ]] && grep -Eiq 'PlushBuddy|PlushPal|Settings|Parent|Welcome' "$RESULT_DIR/window.xml"; then
  echo "PASS: Android app installed, launched, and exposed expected UI text."
  echo "pass" > "$RESULT_DIR/status.txt"
else
  echo "WARN: Android app installed/launched, but expected UI text was not found in the UI dump." >&2
  echo "needs-review" > "$RESULT_DIR/status.txt"
  exit 4
fi

echo "Results: $RESULT_DIR"
