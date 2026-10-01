#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Manifest + machine-type check for the Wine PE output sets (docs/BUILDING.md, "The pipeline" (pe)).

usage: wine-pe-manifest.py <wine-build-dir> <arch-dir> [llvm-readobj]
  e.g. wine-pe-manifest.py $PLAYPORT_BUILD/run/pe/wine/build-arm64ec arm64ec-windows

Walks every file under */<arch-dir>/ in the build tree except intermediates
(.o .a .res and generated testlist .c) and prints one TSV row per artifact:

  path  size  sha256  kind  header_machine  readobj_machine  wine_builtin

kind            pe | pe-data (PE with no executable section: a -Wb,--data-only
                resource/typelib module) | data (not an MZ/PE image)
header_machine  the raw IMAGE_FILE_HEADER.Machine (0xAA64 arm64, 0x8664 amd64)
readobj_machine what llvm-readobj reports; for an ARM64EC image (AMD64 header
                plus CHPE metadata) it reports IMAGE_FILE_MACHINE_ARM64EC
wine_builtin    yes if the "Wine builtin DLL" stamp is at file offset 0x40

Exit status 1 if any code-bearing PE in the set is not the machine the set
claims (aarch64-windows -> ARM64; arm64ec-windows -> ARM64EC). A pe-data image
in the arm64ec set carries no EC code, so lld writes a plain AMD64 header with
no CHPE metadata; AMD64 is accepted for those only.
"""
import hashlib
import os
import struct
import subprocess
import sys

SKIP_EXT = {".o", ".a", ".res", ".c"}
EXPECT = {"aarch64-windows": "IMAGE_FILE_MACHINE_ARM64", "arm64ec-windows": "IMAGE_FILE_MACHINE_ARM64EC"}


def has_code(data, pe):
    nsec, _, _, _, optsize = struct.unpack_from("<HIIIH", data, pe + 6)
    sec = pe + 24 + optsize
    for i in range(nsec):
        if struct.unpack_from("<I", data, sec + 40 * i + 36)[0] & 0x20000000:  # IMAGE_SCN_MEM_EXECUTE
            return True
    return False


def readobj_machine(readobj, path):
    out = subprocess.run([readobj, "--file-headers", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Machine:"):
            return line.split()[1]
    return "?"


def main():
    build, arch_dir = sys.argv[1], sys.argv[2]
    readobj = sys.argv[3] if len(sys.argv) > 3 else "llvm-readobj"
    bad = 0
    rows = []
    for root, _, files in os.walk(build):
        if os.path.basename(root) != arch_dir:
            continue
        for name in files:
            if os.path.splitext(name)[1] in SKIP_EXT:
                continue
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            data = open(path, "rb").read()
            sha = hashlib.sha256(data).hexdigest()
            kind, hdr, ro, builtin = "data", "-", "-", "-"
            if data[:2] == b"MZ" and len(data) > 0x40:
                pe = struct.unpack_from("<I", data, 0x3C)[0]
                if data[pe:pe + 4] == b"PE\0\0":
                    kind = "pe" if has_code(data, pe) else "pe-data"
                    hdr = "0x%04X" % struct.unpack_from("<H", data, pe + 4)[0]
                    ro = readobj_machine(readobj, path)
                    builtin = "yes" if data[0x40:0x40 + 16] == b"Wine builtin DLL" else "no"
                    ok = ro == EXPECT.get(arch_dir, ro)
                    if kind == "pe-data" and arch_dir == "arm64ec-windows":
                        ok = ok or ro == "IMAGE_FILE_MACHINE_AMD64"
                    if not ok:
                        print("MISMATCH: %s is %s" % (path, ro), file=sys.stderr)
                        bad += 1
            rows.append((os.path.relpath(path, build), len(data), sha, kind, hdr, ro, builtin))
    for r in sorted(rows):
        print("\t".join(str(x) for x in r))
    if bad:
        print("MISMATCH: %d PE files are not %s" % (bad, EXPECT[arch_dir]), file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
