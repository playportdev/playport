#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Align a dylib's symbol string table for Xcode's linker (app/Xcode/sync-staged.sh).

lld (the container's linker for Mesa's dylibs) may leave LC_SYMTAB's string
table at an offset that is not a multiple of 8, which Xcode's linker refuses to
link against ("mis-aligned LINKEDIT string pool"). When the string table is the
last thing in the file (no code signature after it), this inserts the padding
before it and moves stroff and __LINKEDIT's size to match. Nothing else moves.

    app/Xcode/align-strtab.py DYLIB...
"""

import struct
import sys

LC_SEGMENT_64, LC_SYMTAB, LC_CODE_SIGNATURE = 0x19, 0x2, 0x1D


def align(path: str) -> str:
    data = bytearray(open(path, "rb").read())
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return "not a thin 64-bit Mach-O"
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, symtab, linkedit = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_SYMTAB:
            symtab = off
        elif cmd == LC_SEGMENT_64 and data[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit = off
        elif cmd == LC_CODE_SIGNATURE:
            raise SystemExit(f"{path}: signed; remove the signature first")
        off += size
    if symtab is None or linkedit is None:
        return "no symbol table"
    stroff, strsize = struct.unpack_from("<II", data, symtab + 16)
    pad = -stroff % 8
    if not pad:
        return "aligned already"
    if stroff + strsize != len(data):
        raise SystemExit(f"{path}: the string table is not last; cannot pad it in place")
    data[stroff:stroff] = bytes(pad)
    struct.pack_into("<I", data, symtab + 16, stroff + pad)
    vmsize, fileoff, filesize = struct.unpack_from("<QQQ", data, linkedit + 32)
    struct.pack_into("<Q", data, linkedit + 48, filesize + pad)
    if filesize + pad > vmsize:
        struct.pack_into("<Q", data, linkedit + 32, (filesize + pad + 0x3FFF) & ~0x3FFF)
    open(path, "wb").write(data)
    return f"string table moved {stroff} -> {stroff + pad}"


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(f"{p.rsplit('/', 1)[-1]}: {align(p)}")
