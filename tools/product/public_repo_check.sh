#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "Checking public-repo hygiene..."

required=(
  README.md
  LICENSE
  CONTRIBUTING.md
  SECURITY.md
  THIRD_PARTY.md
  docs/architecture/SYSTEM_DESIGN.md
  docs/architecture/CODEBASE_DIRECTORY_GUIDE.md
  docs/release/QA_TEST_PLAN_AND_EXECUTION_2026-06-25.md
  docs/product/PRIVACY_AND_SECURITY.md
  docs/product/KNOWN_LIMITATIONS.md
  docs/assets/screenshots/android-welcome.png
  docs/assets/screenshots/iphone-simulator-welcome.png
  docs/assets/screenshots/browser-welcome.png
  docs/assets/screenshots/mac-client-welcome.png
)

for path in "${required[@]}"; do
  if [ ! -s "$path" ]; then
    echo "Missing required public artifact: $path" >&2
    exit 1
  fi
done

secret_pattern='(ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{20,}|BEGIN (RSA |OPENSSH |EC |PRIVATE )?PRIVATE KEY|GEMINI_API_KEY=|OPENAI_API_KEY=|ELEVENLABS_API_KEY=)'
if git ls-files -z | xargs -0 grep -InE "$secret_pattern" -- 2>/dev/null; then
  echo "Potential secret material found in tracked files." >&2
  exit 1
fi

for ignored in audio-samples test-artifacts test-results "qa/results" dist build target ".venv-luxtts" ".venv-chatterbox"; do
  if git ls-files -- "$ignored" | grep -q .; then
    echo "Ignored/generated path is tracked: $ignored" >&2
    exit 1
  fi
done

if grep -RIn 'qa/results/' README.md docs/architecture docs/release docs/product 2>/dev/null \
  | grep -v 'old `qa/results/`' \
  | grep -v 'QA_TEST_PLAN_AND_EXECUTION_2026-06-24.md'; then
  echo "Docs still reference old in-repo qa/results path." >&2
  exit 1
fi

if grep -RIn 'audio-samples/' README.md docs/architecture docs/release docs/product 2>/dev/null \
  | grep -v 'Downloads/PlushPal/private/audio-samples' \
  | grep -v 'Local-only/private folders' \
  | grep -v 'Ignored legacy/dev paths' \
  | grep -v 'ignored' \
  | grep -v 'not be committed'; then
  echo "Docs still reference in-repo audio-samples path as a current path." >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import re
root = Path.cwd()
readme = (root / "README.md").read_text()
for match in re.finditer(r'<img src="([^"]+)"', readme):
    path = root / match.group(1)
    if not path.is_file():
        raise SystemExit(f"README image is missing: {match.group(1)}")
print("README image links OK")
PY

echo "Public-repo hygiene check passed."
