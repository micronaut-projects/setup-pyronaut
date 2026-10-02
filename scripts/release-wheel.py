#!/usr/bin/env python3
"""Download the Pyronaut wheel attached to a GitHub release.

Pyronaut is not published to PyPI. Each release of micronaut-projects/pyronaut
carries the SDK wheel (`pyronaut-<version>-py3-none-any.whl`) as a release
asset instead, so the CLI is installed from there: the same place, and the same
token, that `pyronaut setup` uses for the native launcher bundles.

Assets are fetched through the REST API rather than the browser download URL,
because only the API honours a token for a private repository. The token is
never forwarded on the redirect to the storage host, which serves a presigned
URL and rejects a second credential.

Prints the path of the downloaded wheel on stdout. Only the Python standard
library is used: this runs on the runner's CPython before any environment
exists.

Usage: release-wheel.py --repository OWNER/NAME --version VERSION --dest DIR
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PAGE_SIZE = 100
WHEEL = re.compile(r"^pyronaut-(?P<version>[^-]+)-.+\.whl$")


class ReleaseError(Exception):
    pass


def api_base() -> str:
    return os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")


def request(url: str, accept: str) -> urllib.request.Request:
    req = urllib.request.Request(url, headers={"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"})
    token = os.environ.get("GH_TOKEN", "").strip()
    if token:
        # An unredirected header is dropped when urllib follows a redirect, which
        # is what the presigned asset download needs.
        req.add_unredirected_header("Authorization", f"Bearer {token}")
    return req


def get_json(path: str) -> object | None:
    """GETs an API path and decodes it, returning ``None`` on a 404."""
    try:
        with urllib.request.urlopen(request(api_base() + path, "application/vnd.github+json")) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ReleaseError(f"GET {path} failed: HTTP {error.code} {error.reason}") from error


def wheels(release: dict) -> list[dict]:
    return [asset for asset in release.get("assets", []) if WHEEL.match(asset.get("name", ""))]


def find_release(repository: str, version: str) -> dict:
    """Returns the release to install from, with its assets."""
    if version == "latest":
        # `/releases/latest` skips prereleases, and every Pyronaut release so far
        # is one, so walk the list instead. It is ordered newest first.
        page = 1
        while True:
            releases = get_json(f"/repos/{repository}/releases?per_page={PAGE_SIZE}&page={page}")
            if releases is None:
                raise ReleaseError(not_found(repository))
            for release in releases:
                if not release.get("draft") and wheels(release):
                    return release
            if len(releases) < PAGE_SIZE:
                raise ReleaseError(f"No release of {repository} has a Pyronaut wheel attached.")
            page += 1

    for tag in (f"v{version}", version):
        release = get_json(f"/repos/{repository}/releases/tags/{urllib.parse.quote(tag, safe='')}")
        if release is not None:
            return release
    # A 404 for a tag is indistinguishable from a repository the token cannot
    # see, so check which one it is before blaming the version.
    if get_json(f"/repos/{repository}") is None:
        raise ReleaseError(not_found(repository))
    raise ReleaseError(f"{repository} has no release tagged v{version} or {version}.")


def not_found(repository: str) -> str:
    return (
        f"Cannot read releases of {repository}. While that repository is private, the "
        "`github-token` input needs a token with `contents: read` on it."
    )


def select_wheel(release: dict, version: str) -> dict:
    candidates = wheels(release)
    if version != "latest":
        candidates = [asset for asset in candidates if WHEEL.match(asset["name"]).group("version") == version]
    tag = release.get("tag_name", "?")
    if not candidates:
        raise ReleaseError(f"Release {tag} has no pyronaut-{version if version != 'latest' else '*'}-*.whl asset.")
    if len(candidates) > 1:
        names = ", ".join(sorted(asset["name"] for asset in candidates))
        raise ReleaseError(f"Release {tag} has more than one Pyronaut wheel: {names}")
    return candidates[0]


def download(asset: dict, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / asset["name"]
    try:
        with urllib.request.urlopen(request(asset["url"], "application/octet-stream")) as response:
            with open(target, "wb") as out:
                while chunk := response.read(1 << 20):
                    out.write(chunk)
    except urllib.error.HTTPError as error:
        raise ReleaseError(f"Downloading {asset['name']} failed: HTTP {error.code} {error.reason}") from error
    size = asset.get("size")
    if isinstance(size, int) and target.stat().st_size != size:
        raise ReleaseError(f"Downloaded {asset['name']} is {target.stat().st_size} bytes; expected {size}.")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dest", required=True, type=Path)
    args = parser.parse_args()

    version = args.version.strip() or "latest"
    if version.startswith("v") and version[1:2].isdigit():
        version = version[1:]
    try:
        release = find_release(args.repository, version)
        asset = select_wheel(release, version)
        print(f"Downloading {asset['name']} from {args.repository} release {release['tag_name']}", file=sys.stderr)
        print(download(asset, args.dest))
    except (ReleaseError, urllib.error.URLError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
