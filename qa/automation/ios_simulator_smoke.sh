#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
RESULT_ROOT="${PLUSHPAL_TEST_RESULTS_DIR:-$HOME/Downloads/PlushPal/test-results}"
RESULT_DIR="$RESULT_ROOT/ios-simulator-$(date +%Y%m%d-%H%M%S)"
SIM_ID="${IOS_SIMULATOR_ID:-88C277EE-0A22-41D0-BD5E-C9779545BCA9}"
BUNDLE_ID="${PLUSHPAL_IOS_BUNDLE_ID:-com.plushpal.app}"
APP="${PLUSHPAL_IOS_SIMULATOR_APP:-$PUBLIC_ROOT/artifacts/ios/PlushBuddy-iPhoneSimulator.app}"

mkdir -p "$RESULT_DIR"

if [[ ! -d "$APP" ]]; then
  echo "Simulator app not found at $APP. Run 'make public-artifacts' first, or set PLUSHPAL_IOS_SIMULATOR_APP." >&2
  exit 2
fi

echo "Booting simulator $SIM_ID..."
xcrun simctl boot "$SIM_ID" > "$RESULT_DIR/sim-boot.log" 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b > "$RESULT_DIR/sim-bootstatus.log" 2>&1

echo "Installing and launching PlushBuddy..."
xcrun simctl install "$SIM_ID" "$APP" > "$RESULT_DIR/sim-install.log" 2>&1
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" > "$RESULT_DIR/sim-launch.log" 2>&1
sleep 5

xcrun simctl io "$SIM_ID" screenshot "$RESULT_DIR/launch.png" > "$RESULT_DIR/sim-screenshot.log" 2>&1

echo "PASS: iPhone simulator build installed and launched."
echo "pass" > "$RESULT_DIR/status.txt"
echo "Results: $RESULT_DIR"
