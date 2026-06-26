#!/usr/bin/env python3
"""Create a GitHub release and upload a local PlushBuddy release bundle.

Token lookup order:

1. ``GITHUB_TOKEN`` environment variable
2. macOS Keychain service ``codex.github.token``
3. macOS Keychain service ``plushpal.github.token`` for backward compatibility

Use ``--dry-run`` to validate the bundle and print planned API calls without
making network requests.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


API_ROOT = os.environ.get("GITHUB_API_ROOT", "https://api.github.com")
MAX_RELEASE_ASSET_BYTES = 2_000_000_000


def keychain_token(service: str) -> str | None:
    try:
        completed = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", service, "-w"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except FileNotFoundError:
        return None
    token = completed.stdout.strip()
    return token or None


def github_token() -> str:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        return token
    for service in ("codex.github.token", "plushpal.github.token"):
        token = keychain_token(service)
        if token:
            return token
    raise SystemExit(
        "GITHUB_TOKEN is required. Export it or store it in macOS Keychain service codex.github.token."
    )


def api_request(method: str, path_or_url: str, token: str, body: bytes | None = None, content_type: str = "application/json") -> dict:
    url = path_or_url if path_or_url.startswith("http") else f"{API_ROOT}{path_or_url}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"GitHub API request failed: {method} {url} -> HTTP {error.code}\n{detail}") from error
    if not data:
        return {}
    return json.loads(data.decode("utf-8"))


def release_assets(release_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in release_dir.iterdir()
        if path.is_file() and not path.name.startswith(".")
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("owner")
    parser.add_argument("repo")
    parser.add_argument("tag")
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("--target", default="main")
    parser.add_argument("--name", default=None)
    parser.add_argument("--draft", action="store_true")
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    release_dir = args.release_dir.expanduser().resolve()
    if not release_dir.is_dir():
        raise SystemExit(f"Release directory not found: {release_dir}")
    assets = release_assets(release_dir)
    if not assets:
        raise SystemExit(f"Release directory contains no files: {release_dir}")
    oversized = [
        asset for asset in assets if asset.stat().st_size > MAX_RELEASE_ASSET_BYTES
    ]
    if oversized:
        names = ", ".join(f"{asset.name} ({asset.stat().st_size} bytes)" for asset in oversized)
        raise SystemExit(
            "Release bundle contains assets too large for GitHub release upload: "
            f"{names}. Remove them from the release bundle or set a smaller artifact format."
        )
    checksum = release_dir / "SHA256SUMS"
    notes = release_dir / "RELEASE_NOTES.md"
    if checksum not in assets:
        raise SystemExit("Release bundle must include SHA256SUMS")
    if notes not in assets:
        raise SystemExit("Release bundle must include RELEASE_NOTES.md")

    release_body = notes.read_text(encoding="utf-8")
    release_name = args.name or f"PlushBuddy {args.tag}"
    release_payload = {
        "tag_name": args.tag,
        "target_commitish": args.target,
        "name": release_name,
        "body": release_body,
        "draft": args.draft,
        "prerelease": args.prerelease,
    }

    if args.dry_run:
        print(f"DRY_RUN release {args.owner}/{args.repo} tag={args.tag} target={args.target}")
        for asset in assets:
            print(f"DRY_RUN upload {asset.name} bytes={asset.stat().st_size}")
        return 0

    token = github_token()
    release = api_request(
        "POST",
        f"/repos/{args.owner}/{args.repo}/releases",
        token,
        json.dumps(release_payload).encode("utf-8"),
    )
    upload_url = str(release["upload_url"]).split("{", 1)[0]
    for asset in assets:
        content_type = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
        encoded_name = urllib.parse.quote(asset.name)
        api_request(
            "POST",
            f"{upload_url}?name={encoded_name}",
            token,
            asset.read_bytes(),
            content_type,
        )
        print(f"Uploaded {asset.name}")

    print(f"Release created: {release.get('html_url', f'{args.owner}/{args.repo}:{args.tag}')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
