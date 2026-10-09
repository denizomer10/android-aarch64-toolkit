#!/usr/bin/env python3
"""Patch a platform android.jar so an older aapt2 can read its resources.

The native aarch64 aapt2 (Debian, AOSP 14) can only parse resources.arsc up to
API 34. Newer platforms use an encoding it rejects with
"RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data".

This keeps the target android.jar's (newer) class files but swaps in the older
platform's resources.arsc, so Kotlin/Java compile against the newer API while
aapt2 can link resources.

Usage:
    python3 patch-platform-jar.py --old-jar android-34/android.jar \
                                  --new-jar android-37/android.jar \
                                  --out   android-37/android.jar
"""
from __future__ import annotations

import argparse
import os
import tempfile
import zipfile


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old-jar", required=True, help="jar with the compatible resources.arsc")
    ap.add_argument("--new-jar", required=True, help="jar with the desired class files")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with zipfile.ZipFile(args.old_jar) as z:
        resources = z.read("resources.arsc")

    # Write to a temp file first so --out may equal --new-jar (in-place patch).
    out_dir = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(suffix=".jar", dir=out_dir)
    os.close(fd)
    try:
        with zipfile.ZipFile(args.new_jar) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as out:
            for item in src.infolist():
                data = resources if item.filename == "resources.arsc" else src.read(item.filename)
                out.writestr(item, data)
        os.replace(tmp, args.out)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    print(f"wrote {args.out} (resources.arsc from {args.old_jar})")


if __name__ == "__main__":
    main()
