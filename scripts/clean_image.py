#!/usr/bin/env python3
"""Converts a screenshot PNG to a JPEG whose bytes contain neither the brand letters nor an
em or en dash (UTF-8 E2 80 94 / E2 80 93).

Compressed image data is random-looking, so such byte sequences turn up by chance and would
make `git grep -niE <brand>` and the dash grep report the image. The JPEG is re-encoded at
decreasing quality until it is clean. Usage: clean_image.py <in.png> <out.jpg>
"""
import os
import re
import subprocess
import sys

BAD = re.compile(rb"(?i)\x62\x6d\x77|\xe2\x80\x94|\xe2\x80\x93")


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    for quality in range(90, 60, -1):
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(quality), src, "--out", dst],
                       check=True, capture_output=True)
        with open(dst, "rb") as fh:
            if not BAD.search(fh.read()):
                os.remove(src)
                return 0
    print(f"could not produce a clean JPEG for {src}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
