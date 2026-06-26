#!/usr/bin/env python3
"""Fast regression test for the packaged LuxTTS runtime marker.

This intentionally avoids installing LuxTTS. It builds a tiny fake app-resource
tree and a fake existing venv whose python executable answers the two probes the
installer uses:

- ``python -c ...`` for version support
- ``python luxtts_tts.py --healthcheck`` for runtime readiness

If the marker checksums match, the installer must exit early and avoid deleting
or rebuilding the runtime.
"""

from __future__ import annotations

import hashlib
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "packaging/macos/install_luxtts_runtime.sh"
INSTALLER_VERSION = "2026-06-26-luxtts-runtime-v1"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_executable(path: Path) -> None:
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="plushpal-luxtts-installer-") as tmp:
        root = Path(tmp)
        bundle = root / "bundle"
        venv = root / "luxtts-venv"
        voice_dir = bundle / "voice"
        lux_dir = bundle / "third_party/LuxTTS"
        bin_dir = venv / "bin"
        voice_dir.mkdir(parents=True)
        lux_dir.mkdir(parents=True)
        bin_dir.mkdir(parents=True)

        installer = bundle / "install_luxtts_runtime.sh"
        shutil.copy2(INSTALLER, installer)
        make_executable(installer)

        lux_script = voice_dir / "luxtts_tts.py"
        lux_script.write_text("# fake luxtts wrapper\n", encoding="utf-8")
        requirements = lux_dir / "requirements.txt"
        requirements.write_text("# fake requirements\n", encoding="utf-8")

        fake_python = bin_dir / "python"
        fake_python.write_text(
            """#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "Python 3.12.0"
  exit 0
fi
if [ "$1" = "-c" ]; then
  exit 0
fi
if [ "$2" = "--healthcheck" ]; then
  exit 0
fi
echo "unexpected fake python invocation: $*" >&2
exit 9
""",
            encoding="utf-8",
        )
        make_executable(fake_python)

        marker = venv / ".plushbuddy-luxtts-runtime.env"
        marker.write_text(
            "\n".join(
                [
                    "schema_version=1",
                    f"installer_version={INSTALLER_VERSION}",
                    "installed_at_utc=2026-06-26T00:00:00Z",
                    f"python_path={fake_python}",
                    "python_version=Python 3.12.0",
                    f"requirements_sha256={sha256(requirements)}",
                    f"script_sha256={sha256(lux_script)}",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        completed = subprocess.run(
            ["/bin/sh", str(installer), str(venv)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if completed.returncode != 0:
            raise SystemExit(completed.stdout)
        if "LuxTTS voice runtime already installed." not in completed.stdout:
            raise SystemExit(f"installer did not use marker fast path:\n{completed.stdout}")
        if not fake_python.exists():
            raise SystemExit("installer unexpectedly removed the fake existing runtime")

    print("PASS: LuxTTS installer marker fast path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
