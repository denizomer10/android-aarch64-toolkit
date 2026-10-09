#!/usr/bin/env python3
"""Find the Linux download URL for an Android SDK package in Google's repo.

Reads the official repository manifest and prints the absolute URL of the best
archive for the requested package (host-os = linux). Avoids `sdkmanager`, which
is x86_64-only on Linux.

Usage:
    python3 get-package-url.py --package-prefix "platforms;android-37"
    python3 get-package-url.py --package-prefix "build-tools;36"
"""
from __future__ import annotations

import argparse
import re
import urllib.request
from urllib.parse import urljoin

REPO_BASE = "https://dl.google.com/android/repository/"
REPO_URL = REPO_BASE + "repository2-3.xml"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-prefix", required=True)
    ap.add_argument("--host-os", default="linux")
    ap.add_argument("--repo-url", default=REPO_URL)
    args = ap.parse_args()

    with urllib.request.urlopen(args.repo_url, timeout=120) as resp:
        xml = resp.read().decode("utf-8", "replace")

    best = None  # (revision_tuple, path, absolute_url)
    for m in re.finditer(r'<remotePackage path="([^"]+)".*?</remotePackage>', xml, re.S):
        path, block = m.group(1), m.group(0)
        if not path.startswith(args.package_prefix):
            continue
        rev = re.findall(r"<major>(\d+)</major>\s*<minor>(\d+)</minor>\s*<micro>(\d+)</micro>", block)
        rev_t = tuple(int(x) for x in rev[0]) if rev else (0, 0, 0)

        url = None
        for am in re.finditer(r"<archive>(.*?)</archive>", block, re.S):
            a = am.group(1)
            host = re.search(r"<host-os>([^<]+)</host-os>", a)
            u = re.search(r"<url>([^<]+)</url>", a)
            if u and (host is None or host.group(1) == args.host_os):
                url = urljoin(REPO_BASE, u.group(1))
        if url and (best is None or rev_t > best[0]):
            best = (rev_t, path, url)

    if not best:
        raise SystemExit(f"no {args.host_os} archive found for prefix {args.package_prefix!r}")
    print(best[2])


if __name__ == "__main__":
    main()
