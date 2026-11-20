#!/usr/bin/env python3
"""Watch horizon-rust/horizon releases and copy their version verbatim.

Outputs (GITHUB_OUTPUT):
  changed, nightly_date, nightly_commit, nightly_short, nightly_tag,
  game_ref, version_tag, launcher_version
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.github.com"
REPO = "horizon-rust/horizon"


def fetch_json(url):
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "H-RUST-monitor"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=40) as response:
        return json.load(response)


def launcher_version(releases):
    best = None
    for release in releases:
        match = re.fullmatch(r"launcher@(\d+)\.(\d+)\.(\d+)", release.get("tag_name", ""))
        if not match:
            continue
        key = tuple(int(part) for part in match.groups())
        if best is None or key > best[0]:
            best = (key, release["tag_name"])
    return best[1] if best else ""


def nightly_info(releases):
    for release in releases:
        if release.get("tag_name") != "nightly":
            continue
        body = release.get("body") or ""
        head = re.search(r"Nightly\s+(\d{4}-\d{2}-\d{2})\s+[·-]\s+([0-9a-f]{7,40})", body)
        source = re.search(r"Source:\s*commit\s+([0-9a-f]{40})", body, re.I)
        if not head:
            raise RuntimeError("nightly release body has no 'Nightly YYYY-MM-DD · commit' line")
        date, short = head.group(1), head.group(2)[:7]
        full = source.group(1) if source else head.group(2)
        return {
            "date": date,
            "commit": full,
            "short": short,
            "tag": f"nightly-source/{date}-{short}",
            "published_at": release.get("published_at", ""),
        }
    raise RuntimeError("no release tagged 'nightly' found")


def load_state(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="state/upstream.json")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    releases = fetch_json(f"{API}/repos/{REPO}/releases?per_page=30")
    nightly = nightly_info(releases)
    launcher = launcher_version(releases)
    version_tag = f"nightly-{nightly['date']}-{nightly['short']}"

    current = load_state(args.state)
    same = (
        current.get("nightly", {}).get("commit") == nightly["commit"]
        and current.get("launcher") == launcher
    )
    changed = args.force or not same

    state = {
        "nightly": nightly,
        "launcher": launcher,
        "version_tag": version_tag,
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if changed:
        path = Path(args.state)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")

    outputs = {
        "changed": "true" if changed else "false",
        "nightly_date": nightly["date"],
        "nightly_commit": nightly["commit"],
        "nightly_short": nightly["short"],
        "nightly_tag": nightly["tag"],
        "game_ref": nightly["tag"],
        "version_tag": version_tag,
        "launcher_version": launcher,
    }
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")
    print(json.dumps({**outputs, "state_written": changed}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"monitor failed: {error}", file=sys.stderr)
        sys.exit(1)
