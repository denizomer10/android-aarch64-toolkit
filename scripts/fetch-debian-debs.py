#!/usr/bin/env python3
"""Download Debian arm64 packages (and their dependency closure) and unpack them.

Used to obtain natively-built arm64 Android tools (e.g. aapt2, libxml2) that
Google does not publish for aarch64 Linux. Works without apt/dpkg: it talks to
the Debian archive directly and unpacks `.deb` (ar + data.tar.*) into a prefix.

Usage:
    python3 fetch-debian-debs.py --root-package aapt \
        --dest ~/Android/debian/root [--root-package libxml2-16] \
        [--suite trixie] [--arch arm64]
"""
from __future__ import annotations

import argparse
import bz2
import gzip
import io
import lzma
import os
import re
import tarfile
import urllib.request

BASE = "http://deb.debian.org/debian"

# Provided by the host distro (glibc/libstdc++/libgcc); skip them.
DEFAULT_SKIP = {"libc6", "libstdc++6", "libgcc-s1", "libatomic1"}


def fetch(url: str, timeout: int = 240) -> bytes:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def load_index(suite: str, arch: str) -> dict[str, dict]:
    url = f"{BASE}/dists/{suite}/main/binary-{arch}/Packages.xz"
    print(f"fetching index {url}", flush=True)
    text = lzma.decompress(fetch(url)).decode("utf-8", "replace")
    packages: dict[str, dict] = {}
    cur: dict[str, str] = {}
    for line in text.splitlines():
        if line.startswith("Package: "):
            cur["Package"] = line[9:].strip()
        elif line.startswith("Version: "):
            cur["Version"] = line[9:].strip()
        elif line.startswith("Depends: "):
            cur["Depends"] = line[9:].strip()
        elif line.startswith("Provides: "):
            cur["Provides"] = line[10:].strip()
        elif line.startswith("Filename: "):
            cur["Filename"] = line[10:].strip()
        elif line == "":
            if "Package" in cur:
                packages[cur["Package"]] = cur
            cur = {}
    if "Package" in cur:
        packages[cur["Package"]] = cur
    return packages


def dep_names(pkg: dict) -> list[str]:
    out = []
    for clause in pkg.get("Depends", "").split(","):
        clause = clause.strip()
        if not clause:
            continue
        alt = clause.split("|")[0].strip()
        name = re.sub(r"\(.*\)", "", alt).strip().split(" ")[0].split(":")[0].strip()
        if name:
            out.append(name)
    return out


def resolve(packages: dict, roots: list[str], skip: set[str]) -> list[str]:
    provides: dict[str, str] = {}
    for name, p in packages.items():
        for pr in p.get("Provides", "").split(","):
            vn = pr.strip().split(" ")[0].split("|")[0].strip()
            if vn:
                provides.setdefault(vn, name)

    want, seen, queue = set(), set(), list(roots)
    while queue:
        n = queue.pop()
        if n in seen or n in skip:
            continue
        seen.add(n)
        p = packages.get(n) or packages.get(provides.get(n, ""))
        if not p:
            print(f"  (unresolved: {n})", flush=True)
            continue
        want.add(p["Package"])
        queue.extend(dep_names(p))
    return sorted(want)


def ar_members(data: bytes) -> dict[str, bytes]:
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off, members = 8, {}
    while off < len(data):
        hdr = data[off : off + 60]
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode().strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        members[name] = data[off + 60 : off + 60 + size]
        off += 60 + size + (size % 2)
    return members


def extract_data_tar(body: bytes, dest: str) -> None:
    # Debian data.tar.* can be gz, bz2, xz or zstd. Handle them all without
    # relying on external tools when possible.
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    elif body[:3] == b"BZh":
        body = bz2.decompress(body)
    elif body[:6] == b"\xfd7zXZ\x00":
        body = lzma.decompress(body)
    elif body[:4] == b"\x28\xb5\x2f\xfd":
        try:
            import zstandard  # type: ignore
            body = zstandard.ZstdDecompressor().decompress(body)
        except ImportError:
            import shutil
            import subprocess
            zstd = shutil.which("zstd") or shutil.which("unzstd")
            if not zstd:
                raise RuntimeError("zstd-compressed .deb but no 'zstandard' module or 'zstd' binary")
            body = subprocess.run(
                [zstd, "-dc"], input=body, stdout=subprocess.PIPE, check=True
            ).stdout
    with tarfile.open(fileobj=io.BytesIO(body)) as tf:
        tf.extractall(dest)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root-package", action="append", required=True)
    ap.add_argument("--suite", default="trixie")
    ap.add_argument("--arch", default="arm64")
    ap.add_argument("--dest", default=os.path.expanduser("~/Android/debian/root"))
    ap.add_argument("--skip", default=",".join(sorted(DEFAULT_SKIP)))
    args = ap.parse_args()

    skip = {s.strip() for s in args.skip.split(",") if s.strip()}
    os.makedirs(args.dest, exist_ok=True)
    packages = load_index(args.suite, args.arch)
    print(f"index size: {len(packages)}", flush=True)
    need = resolve(packages, args.root_package, skip)
    print("resolved:", need, flush=True)

    for name in need:
        p = packages[name]
        try:
            members = ar_members(fetch(f"{BASE}/{p['Filename']}"))
            data_name = next(k for k in members if k.startswith("data.tar"))
            extract_data_tar(members[data_name], args.dest)
            print(f"ok: {name} {p['Version']}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL: {name}: {exc!r}", flush=True)

    print(f"done -> {args.dest}", flush=True)


if __name__ == "__main__":
    main()
