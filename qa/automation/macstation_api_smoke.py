#!/usr/bin/env python3
"""MacStation API smoke/E2E test.

This starts the Rust MacStation host in an isolated temporary data directory,
exchanges the bootstrap token for a session cookie, validates health/status,
configures the parent PIN, creates characters, and optionally enrolls voice
samples for each character.

By default this is a fast API smoke and does not load LuxTTS. Pass
`--runtime-mode demo --synthesize` to exercise the public demo mode,
`--voice-engine luxtts --synthesize` to exercise the local voice runtime too,
or `--voice-engine demo --synthesize` for a lightweight synthetic voice smoke.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse


ROOT = Path(__file__).resolve().parents[2]
RESULTS_ROOT = Path(
    os.environ.get("PLUSHPAL_TEST_RESULTS_DIR", str(Path.home() / "Downloads" / "PlushPal" / "test-results"))
)


def request(
    base_url: str,
    method: str,
    path: str,
    *,
    cookie: str | None = None,
    bootstrap: str | None = None,
    body: dict[str, Any] | None = None,
    query: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    parsed = urlparse(base_url)
    target = path
    if query:
        target += "?" + urlencode(query)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=120)
    headers: dict[str, str] = {
        "Host": f"{parsed.hostname}:{parsed.port}",
        "Origin": base_url,
    }
    payload: bytes | None = None
    if cookie:
        headers["Cookie"] = cookie
    if bootstrap:
        headers["x-plushpal-bootstrap"] = bootstrap
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    conn.request(method, target, body=payload, headers=headers)
    response = conn.getresponse()
    data = response.read()
    response_headers = {key.lower(): value for key, value in response.getheaders()}
    conn.close()
    return response.status, response_headers, data


def expect(status: int, expected: set[int], label: str, body: bytes = b"") -> None:
    if status not in expected:
        suffix = f" body={body[:500]!r}" if body else ""
        raise AssertionError(f"{label}: expected {sorted(expected)}, got {status}.{suffix}")


def parse_json(data: bytes) -> Any:
    return json.loads(data.decode("utf-8"))


def read_line_until(process: subprocess.Popen[str], pattern: str, timeout: float) -> str:
    deadline = time.time() + timeout
    collected: list[str] = []
    regex = re.compile(pattern)
    while time.time() < deadline:
        line = process.stdout.readline() if process.stdout else ""
        if line:
            collected.append(line.rstrip())
            if regex.search(line):
                return "\n".join(collected)
        elif process.poll() is not None:
            break
        else:
            time.sleep(0.1)
    raise TimeoutError(f"Timed out waiting for {pattern!r}. Output:\n" + "\n".join(collected))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pin", default="1234")
    parser.add_argument(
        "--runtime-mode",
        choices=["custom", "mock", "demo", "local_voice", "cloud", "full"],
        default="custom",
    )
    parser.add_argument("--voice-engine", choices=["none", "demo", "luxtts"], default="none")
    parser.add_argument("--synthesize", action="store_true")
    parser.add_argument(
        "--sample",
        action="append",
        default=[],
        metavar="ALIAS=PATH",
        help="Enroll sample for alias. Can be repeated, e.g. Sheru=audio-samples/Sheru.m4a",
    )
    parser.add_argument("--keep-data", action="store_true")
    args = parser.parse_args()

    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    result_dir = RESULTS_ROOT / f"macstation-api-{time.strftime('%Y%m%d-%H%M%S')}"
    result_dir.mkdir()
    data_dir = Path(tempfile.mkdtemp(prefix="plushbuddy-station-e2e-"))

    env = os.environ.copy()
    env.update(
        {
            "CARGO_TARGET_DIR": env.get(
                "CARGO_TARGET_DIR",
                str(Path.home() / "Downloads" / "PlushPal" / "test-build" / "cargo-target"),
            ),
            "PLUSHPAL_NO_BROWSER": "1",
            "PLUSHPAL_PRINT_BOOTSTRAP_URL": "1",
            "PLUSHPAL_PORT": "0",
            "PLUSHPAL_DATA_DIR": str(data_dir),
            "PLUSHPAL_MODEL_DIR": str(data_dir / "models"),
            "PLUSHPAL_ENABLE_MAC_KEYCHAIN_GEMINI": "0",
        }
    )
    if args.runtime_mode != "custom":
        env["PLUSHPAL_RUNTIME_MODE"] = args.runtime_mode
    if args.voice_engine == "demo":
        env["PLUSHPAL_VOICE_ENGINE"] = "demo"
    elif args.voice_engine == "luxtts":
        env.update(
            {
                "PLUSHPAL_VOICE_ENGINE": "luxtts",
                "PLUSHPAL_LUXTTS_PYTHON": env.get(
                    "PLUSHPAL_LUXTTS_PYTHON",
                    str(
                        Path.home()
                        / "Downloads"
                        / "PlushPal"
                        / "artifacts"
                        / "macos"
                        / "PlushBuddy Station.app"
                        / "Contents"
                        / "Resources"
                        / "python"
                        / "bin"
                        / "python"
                    ),
                ),
                "PLUSHPAL_LUXTTS_SCRIPT": env.get(
                    "PLUSHPAL_LUXTTS_SCRIPT",
                    str(
                        Path.home()
                        / "Downloads"
                        / "PlushPal"
                        / "artifacts"
                        / "macos"
                        / "PlushBuddy Station.app"
                        / "Contents"
                        / "Resources"
                        / "voice"
                        / "luxtts_tts.py"
                    ),
                ),
                "PLUSHPAL_LUXTTS_NUM_STEPS": env.get("PLUSHPAL_LUXTTS_NUM_STEPS", "8"),
                "PLUSHPAL_LUXTTS_SPEED": env.get("PLUSHPAL_LUXTTS_SPEED", "0.88"),
                "PLUSHPAL_LUXTTS_SEED": env.get("PLUSHPAL_LUXTTS_SEED", "11"),
                "PLUSHPAL_LUXTTS_REF_DURATION": env.get("PLUSHPAL_LUXTTS_REF_DURATION", "180"),
            }
        )

    command = [
        "cargo",
        "run",
        "--release",
        "-p",
        "plushpal-desktop-host",
        "--features",
        "native-runtime",
    ]
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        preexec_fn=os.setsid,
    )

    report: dict[str, Any] = {
        "result_dir": str(result_dir),
        "data_dir": str(data_dir),
        "voice_engine": args.voice_engine,
        "checks": [],
    }

    try:
        output = read_line_until(process, r"PlushPal test bootstrap URL:", timeout=180)
        (result_dir / "host-startup.log").write_text(output + "\n")
        match = re.search(r"PlushPal test bootstrap URL: (http://[^\s]+)", output)
        if not match:
            raise AssertionError("Could not parse bootstrap URL")
        bootstrap_url = match.group(1)
        parsed = urlparse(bootstrap_url)
        base_url = f"{parsed.scheme}://{parsed.netloc}"
        bootstrap = parse_qs(parsed.fragment).get("bootstrap", [""])[0]
        if not bootstrap:
            raise AssertionError("Missing bootstrap token")

        status, headers, body = request(base_url, "GET", "/api/v1/health")
        expect(status, {200}, "health", body)
        health = parse_json(body)
        report["checks"].append({"name": "health", "status": status, "body": health})

        status, headers, body = request(
            base_url, "POST", "/api/v1/bootstrap", bootstrap=bootstrap
        )
        expect(status, {204}, "bootstrap exchange", body)
        cookie = headers.get("set-cookie", "").split(";", 1)[0]
        if not cookie:
            raise AssertionError("Bootstrap did not return session cookie")
        report["checks"].append({"name": "bootstrap", "status": status})

        status, headers, body = request(base_url, "GET", "/api/v1/status", cookie=cookie)
        expect(status, {200}, "status", body)
        report["checks"].append({"name": "status", "status": status, "body": parse_json(body)})

        status, headers, body = request(base_url, "GET", "/api/v1/diagnostics")
        expect(status, {401}, "unauthenticated diagnostics", body)
        report["checks"].append({"name": "diagnostics_requires_authentication", "status": status})

        status, headers, body = request(base_url, "GET", "/api/v1/diagnostics", cookie=cookie)
        expect(status, {200}, "diagnostics", body)
        diagnostics = parse_json(body)
        for forbidden in ["pin", "api_key", "prompt", "child_text"]:
            if forbidden in json.dumps(diagnostics).lower():
                raise AssertionError(f"diagnostics leaked forbidden term {forbidden!r}")
        report["checks"].append({"name": "diagnostics", "status": status, "body": diagnostics})

        pin_payload = {
            "pin": args.pin,
            "age_band": "4-5",
            "character_alias": "Buddy",
            "character_traits": ["playful", "gentle"],
            "parent_guidance": "Keep answers friendly, toddler-like, and brief.",
            "retention_days": 1,
        }
        status, headers, body = request(
            base_url, "POST", "/api/v1/parent-pin/configure", cookie=cookie, body=pin_payload
        )
        expect(status, {204}, "configure parent pin", body)
        report["checks"].append({"name": "configure_parent_pin", "status": status})

        for alias in ["Sheru", "Jenna", "Buddy"]:
            status, headers, body = request(
                base_url,
                "POST",
                "/api/v1/characters/save",
                cookie=cookie,
                body={
                    "pin": args.pin,
                    "character_alias": alias,
                    "character_traits": ["cheerful", "curious"],
                    "parent_guidance": f"{alias} should speak like a pretend-play plush toy.",
                },
            )
            expect(status, {204}, f"save character {alias}", body)
            report["checks"].append({"name": f"save_character_{alias}", "status": status})

        status, headers, body = request(base_url, "GET", "/api/v1/characters", cookie=cookie)
        expect(status, {200}, "list characters", body)
        characters = parse_json(body)
        report["checks"].append({"name": "list_characters", "status": status, "body": characters})

        profile_ids: dict[str, str] = {}
        status_profile_ids: dict[str, str] = {}
        for item in args.sample:
            alias, _, raw_path = item.partition("=")
            if not alias or not raw_path:
                raise AssertionError(f"Invalid --sample value: {item}")
            sample_path = (ROOT / raw_path).resolve() if not Path(raw_path).is_absolute() else Path(raw_path)
            sample_bytes = sample_path.read_bytes()
            body_payload = {
                "pin": args.pin,
                "adult_authorized": True,
                "character_alias": alias,
                "source_audio_base64": base64.b64encode(sample_bytes).decode("ascii"),
                "source_filename": sample_path.name,
                "source_mime": "audio/mp4",
            }
            status, headers, body = request(
                base_url,
                "POST",
                "/api/v1/voice/enroll",
                cookie=cookie,
                body=body_payload,
            )
            expect(status, {200}, f"enroll voice {alias}", body)
            voice_status = parse_json(body)
            profile_ids[alias] = voice_status.get("profile_id")
            report["checks"].append({"name": f"enroll_voice_{alias}", "status": status, "body": voice_status})

            status, headers, body = request(
                base_url,
                "POST",
                "/api/v1/voice/approve",
                cookie=cookie,
                body={"pin": args.pin, "character_alias": alias},
            )
            expect(status, {204}, f"approve voice {alias}", body)
            report["checks"].append({"name": f"approve_voice_{alias}", "status": status})

            status, headers, body = request(
                base_url,
                "GET",
                "/api/v1/voice/status",
                cookie=cookie,
                query={"character_alias": alias},
            )
            expect(status, {200}, f"voice status {alias}", body)
            status_body = parse_json(body)
            status_profile_ids[alias] = status_body.get("profile_id")
            if status_profile_ids[alias] != profile_ids[alias]:
                raise AssertionError(
                    f"{alias} profile_id changed after approval: "
                    f"enroll={profile_ids[alias]!r} status={status_profile_ids[alias]!r}"
                )
            report["checks"].append({"name": f"voice_status_{alias}", "status": status, "body": status_body})

            if args.synthesize:
                status, headers, wav = request(
                    base_url,
                    "POST",
                    "/api/v1/voice/speak",
                    cookie=cookie,
                    body={"text": f"Hi, I am {alias}.", "character_alias": alias},
                )
                expect(status, {200}, f"synthesize voice {alias}", wav)
                wav_path = result_dir / f"{alias}-speak.wav"
                wav_path.write_bytes(wav)
                report["checks"].append({"name": f"synthesize_voice_{alias}", "status": status, "bytes": len(wav)})

        if profile_ids:
            if len(set(profile_ids.values())) != len(profile_ids):
                raise AssertionError(f"Voice profile IDs were not unique: {profile_ids}")
            if len(set(status_profile_ids.values())) != len(status_profile_ids):
                raise AssertionError(
                    f"Post-approval voice profile IDs were not unique: {status_profile_ids}"
                )
            report["checks"].append({
                "name": "voice_profile_ids_unique",
                "profile_ids": profile_ids,
                "status_profile_ids": status_profile_ids,
            })

        if args.runtime_mode == "demo":
            request_id = f"demo-turn-{int(time.time())}"
            status, headers, body = request(
                base_url,
                "POST",
                "/api/v1/commands",
                cookie=cookie,
                body={
                    "schema_version": 1,
                    "request_id": request_id,
                    "command": "begin_local_turn",
                    "payload": {
                        "age_band": "4-5",
                        "character_alias": "Buddy",
                        "text": "Can we play puppy spaceship?",
                    },
                },
            )
            expect(status, {202}, "demo child turn command", body)
            accepted = parse_json(body)
            if accepted.get("event") != "command_accepted":
                raise AssertionError(f"unexpected command event: {accepted}")
            report["checks"].append({"name": "demo_child_turn_command", "status": status, "body": accepted})

            history = []
            deadline = time.time() + 10
            while time.time() < deadline:
                status, headers, body = request(
                    base_url,
                    "POST",
                    "/api/v1/history/list",
                    cookie=cookie,
                    body={"pin": args.pin},
                )
                expect(status, {200}, "demo history list", body)
                history = parse_json(body)
                if any(item.get("child_text") == "Can we play puppy spaceship?" for item in history):
                    break
                time.sleep(0.2)
            matching = [item for item in history if item.get("child_text") == "Can we play puppy spaceship?"]
            if not matching:
                raise AssertionError(f"demo turn was not recorded in history: {history}")
            speech = matching[0].get("character_text", "")
            if "Buddy heard you say" not in speech:
                raise AssertionError(f"unexpected demo speech in history: {speech!r}")
            report["checks"].append({
                "name": "demo_child_turn_history",
                "status": status,
                "speech": speech,
            })

        report["status"] = "pass"
        (result_dir / "report.json").write_text(json.dumps(report, indent=2))
        print(f"PASS: MacStation API smoke completed. Results: {result_dir}")
        return 0
    except Exception as exc:  # noqa: BLE001
        report["status"] = "fail"
        report["error"] = str(exc)
        (result_dir / "report.json").write_text(json.dumps(report, indent=2))
        print(f"FAIL: {exc}. Results: {result_dir}", file=sys.stderr)
        return 1
    finally:
        if process.poll() is None:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        if not args.keep_data:
            shutil.rmtree(data_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
