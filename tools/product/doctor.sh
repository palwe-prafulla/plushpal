#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLIC_ROOT="${PLUSHPAL_PUBLIC_ROOT:-$HOME/Downloads/PlushPal}"
failures=0
warnings=0

section() {
  printf '\n== %s ==\n' "$1"
}

pass() {
  printf '✓ %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf '⚠ %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf '✗ %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

version_line() {
  "$@" 2>&1 | head -n 1
}

section "PlushBuddy doctor"
echo "Repo: $ROOT_DIR"
echo "External artifact root: $PUBLIC_ROOT"

section "Host"
os_name="$(uname -s 2>/dev/null || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
echo "OS: $os_name"
echo "Arch: $arch"
if [ "$os_name" = "Darwin" ]; then
  pass "macOS host detected"
else
  warn "Current full voice path is validated primarily on Apple Silicon macOS"
fi
if [ "$arch" = "arm64" ]; then
  pass "Apple Silicon / arm64 detected"
else
  warn "LuxTTS production path is tuned for Apple Silicon; other hosts may need extra work"
fi

available_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
available_gb=$((available_kb / 1024 / 1024))
if [ "$available_gb" -ge 20 ]; then
  pass "Disk space looks OK: ${available_gb}GB available under HOME"
else
  warn "Low disk space: ${available_gb}GB available. LuxTTS/build artifacts can be large."
fi

section "Core build tools"
if have git; then pass "git: $(version_line git --version)"; else fail "git not found"; fi
if have rustup; then pass "rustup: $(version_line rustup --version)"; else fail "rustup not found"; fi
if have cargo; then
  pass "cargo: $(version_line cargo --version)"
  rustc_version="$(rustc --version 2>/dev/null || true)"
  if printf '%s' "$rustc_version" | grep -q '1.86.0'; then
    pass "Rust toolchain matches rust-toolchain.toml: $rustc_version"
  else
    warn "Rust toolchain is '$rustc_version'. rustup should auto-use 1.86.0 from rust-toolchain.toml."
  fi
else
  fail "cargo not found"
fi
if have cmake; then pass "cmake: $(version_line cmake --version)"; else fail "cmake not found"; fi
if have node; then pass "node: $(version_line node --version)"; else fail "node not found"; fi
if have python3; then pass "python3: $(version_line python3 --version)"; else fail "python3 not found"; fi

section "Flutter/mobile"
if have flutter; then
  pass "flutter: $(version_line flutter --version)"
  flutter doctor -v >/tmp/plushbuddy-flutter-doctor.txt 2>&1
  if grep -q 'Android toolchain.*develop for Android devices' /tmp/plushbuddy-flutter-doctor.txt; then
    pass "Flutter Android toolchain detected"
  else
    warn "Flutter Android toolchain may not be ready; run flutter doctor -v"
  fi
  if grep -q 'Xcode.*develop for iOS and macOS' /tmp/plushbuddy-flutter-doctor.txt; then
    pass "Flutter sees Xcode/iOS support"
  else
    warn "Flutter may not see full Xcode/iOS support; run flutter doctor -v"
  fi
else
  fail "flutter not found"
fi
if have adb; then pass "adb detected"; else warn "adb not found; Android device smoke tests will be skipped"; fi
if have xcodebuild; then pass "xcodebuild: $(version_line xcodebuild -version)"; else warn "xcodebuild not found; iOS/macOS packaging unavailable"; fi
if have pod; then pass "CocoaPods: $(version_line pod --version)"; else warn "CocoaPods not found; iOS plugins may not build"; fi
if have cargo-ndk; then pass "cargo-ndk detected"; else warn "cargo-ndk not found; Android Rust native build may be skipped"; fi

section "Repo health"
if [ -f "$ROOT_DIR/LICENSE" ]; then pass "LICENSE present"; else fail "LICENSE missing"; fi
if [ -f "$ROOT_DIR/README.md" ]; then pass "README present"; else fail "README missing"; fi
if [ -f "$ROOT_DIR/SECURITY.md" ]; then pass "SECURITY.md present"; else warn "SECURITY.md missing"; fi
if [ -f "$ROOT_DIR/THIRD_PARTY.md" ]; then pass "THIRD_PARTY.md present"; else warn "THIRD_PARTY.md missing"; fi
if [ -f "$ROOT_DIR/.github/workflows/ci.yml" ]; then pass "GitHub CI workflow present"; else warn "GitHub CI workflow missing"; fi
if [ -f "$ROOT_DIR/docs/assets/screenshots/android-welcome.png" ]; then pass "README screenshot assets present"; else warn "README screenshot assets missing"; fi

section "Local model/runtime cache"
if [ -d "$PUBLIC_ROOT/deps/LuxTTS" ]; then
  pass "LuxTTS source cache exists at $PUBLIC_ROOT/deps/LuxTTS"
else
  warn "LuxTTS source cache is not downloaded yet; make public-artifacts will download it"
fi
if [ -d "$PUBLIC_ROOT/artifacts" ]; then
  pass "Artifact directory exists at $PUBLIC_ROOT/artifacts"
else
  warn "Artifact directory does not exist yet; make public-artifacts will create it"
fi

section "Summary"
if [ "$failures" -eq 0 ]; then
  pass "Doctor completed with $warnings warning(s) and no hard failures"
  exit 0
fi

fail "Doctor found $failures hard failure(s) and $warnings warning(s)"
exit 1
