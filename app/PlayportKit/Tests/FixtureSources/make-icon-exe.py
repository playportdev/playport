#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build PlayportKitTests/Fixtures/icon.exe, the PEIconTests fixture.

  app/PlayportKit/Tests/FixtureSources/make-icon-exe.py

An x86-64 console program that does nothing, with one icon group of two
images: 16x16 as a 32-bit DIB and 48x48 as a PNG (the test expects the
48-pixel PNG to be picked). The pixels are generated here, so this script is
the whole source. Needs llvm-mingw ($LLVM_MINGW, from .work/inputs.local).
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
OUT = HERE.parent / "PlayportKitTests" / "Fixtures" / "icon.exe"


def pixel(x, y, n):
    """A diagonal amber-on-navy stripe pattern, RGBA."""
    on = (x + y) % max(2, n // 4) < max(1, n // 8)
    return (245, 181, 68, 255) if on else (21, 26, 33, 255)


def png(n):
    raw = b"".join(b"\0" + bytes(c for x in range(n) for c in pixel(x, y, n)) for y in range(n))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def dib(n):
    header = struct.pack("<IiiHHIIiiII", 40, n, 2 * n, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = b"".join(bytes(c for x in range(n) for c in (lambda p: (p[2], p[1], p[0], p[3]))(pixel(x, y, n)))
                    for y in reversed(range(n)))
    mask = b"\0" * (((n + 31) // 32) * 4 * n)
    return header + rows + mask


def ico(images):
    head = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for n, data in images:
        entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    return head + entries + blobs


def llvm_mingw():
    if os.environ.get("LLVM_MINGW"):
        return Path(os.environ["LLVM_MINGW"])
    for line in (REPO / ".work" / "inputs.local").read_text().splitlines():
        if line.startswith("LLVM_MINGW="):
            return Path(line.split("=", 1)[1])
    sys.exit("make-icon-exe: set LLVM_MINGW or run ./pp setup")


def main():
    bin_ = llvm_mingw() / "bin"
    (REPO / ".work").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=REPO / ".work") as tmp:
        t = Path(tmp)
        (t / "icon.ico").write_bytes(ico([(16, dib(16)), (48, png(48))]))
        (t / "icon.rc").write_text('1 ICON "icon.ico"\n')
        (t / "main.c").write_text("int main(void) { return 0; }\n")
        subprocess.run([bin_ / "x86_64-w64-mingw32-windres", "icon.rc", "-O", "coff", "-o", "icon.res"], cwd=t, check=True)
        subprocess.run([bin_ / "x86_64-w64-mingw32-clang", "-Os", "-s", "-Wl,--no-insert-timestamp",
                        "main.c", "icon.res", "-o", str(OUT)], cwd=t, check=True)
    print(OUT.relative_to(REPO))


if __name__ == "__main__":
    main()
