#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The staged native pieces for the iOS Simulator, to try the UI on a simulated
phone (an iPhone Duo's two panels, say) on a Mac.

The pipeline builds every native piece for arm64 iOS devices. An Apple silicon
simulator runs the same arm64 code; only the platform each Mach-O names
differs (LC_BUILD_VERSION: IOS 2, IOSSIMULATOR 7). This rewrites that field:

  app/Staged/lib/*.a                 -> OUT/lib/*.a (every member object)
  app/Staged/<X>.xcframework         -> gains an ios-arm64-simulator slice
                                        (its dylib rewritten and signed ad hoc;
                                        Mesa's, which need Metal 4, as empty stand-ins)

Nothing in a simulator can run a game (no JIT, no TXM, no real Metal limits):
this is for the app's own UI. The Xcode project links OUT/lib before
Staged/lib for the simulator SDK (app/Xcode/project.yml).

    app/Xcode/simulator-staged.py [STAGED [OUT]]
      STAGED  default app/Staged
      OUT     default .work/simulator (in the repository)
"""

import os
import plistlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS, PLATFORM_IOSSIMULATOR = 2, 7
# Frameworks whose simulator slice is an empty stand-in (simulator_slice).
STANDINS = {"KosmicKrisp", "MesaEGL", "MesaGallium"}


def patch_macho(data: bytearray, what: str) -> int:
    """Rewrites a thin arm64 Mach-O's platform in place; the number of commands changed."""
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        return 0
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, changed = 32, 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", data, off + 8)[0]
            if platform == PLATFORM_IOS:
                struct.pack_into("<I", data, off + 8, PLATFORM_IOSSIMULATOR)
                changed += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            raise SystemExit(f"{what}: LC_VERSION_MIN_IPHONEOS has no simulator form in place")
        off += size
    return changed


def patch_archive(src: Path, dst: Path) -> tuple[int, int]:
    """Copies an ar archive, rewriting every Mach-O member; (members, changed)."""
    data = bytearray(src.read_bytes())
    if data[:8] != b"!<arch>\n":
        raise SystemExit(f"{src}: not an ar archive")
    off, members, changed = 8, 0, 0
    while off < len(data):
        header = data[off:off + 60]
        name = header[:16].decode().strip()
        size = int(header[48:58].decode().strip())
        body = off + 60
        start, length = body, size
        if name.startswith("#1/"):          # BSD long name: it precedes the member's bytes
            n = int(name[3:])
            start, length = body + n, size - n
        member = bytearray(data[start:start + length])
        c = patch_macho(member, f"{src.name}({name})")
        if c:
            data[start:start + length] = member
            changed += c
        members += 1
        off = body + size + (size & 1)
    dst.write_bytes(data)
    return members, changed


def simulator_slice(xcf: Path) -> None:
    """Adds an ios-arm64-simulator slice to a dynamic-framework xcframework."""
    info = plistlib.loads((xcf / "Info.plist").read_bytes())
    libs = info["AvailableLibraries"]
    if any(l.get("SupportedPlatformVariant") == "simulator" for l in libs):
        return
    device = next(l for l in libs if l["SupportedPlatform"] == "ios" and "SupportedPlatformVariant" not in l)
    src = xcf / device["LibraryIdentifier"] / device["LibraryPath"]
    ident = "ios-arm64-simulator"
    dst = xcf / ident / device["LibraryPath"]
    shutil.rmtree(xcf / ident, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=True)
    binary = dst / Path(device["LibraryPath"]).stem
    if binary.name in STANDINS:
        # Mesa's drivers need Metal 4, which the simulator lacks, and the app links them:
        # an empty library of the same name, so that the app launches (no game runs there).
        src = dst.parent / f"{binary.name}-standin.c"
        src.write_text(f"int playport_simulator_{binary.name}_standin;\n")
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios26.0-simulator",
                        "-dynamiclib", "-install_name", f"@rpath/{binary.name}.framework/{binary.name}",
                        "-o", str(binary), str(src)], check=True)
        src.unlink()
    else:
        data = bytearray(binary.read_bytes())
        if not patch_macho(data, str(binary)):
            raise SystemExit(f"{binary}: no iOS build version to rewrite")
        binary.write_bytes(data)
    # A Swift framework's interfaces, under the simulator's triple.
    for f in list((dst / "Modules").glob("*.swiftmodule/arm64-apple-ios.*")):
        sim = f.with_name(f.name.replace("arm64-apple-ios.", "arm64-apple-ios-simulator.", 1))
        if f.suffix == ".swiftinterface":
            text = f.read_text()
            head, _, rest = text.partition("-target ")
            triple, _, tail = rest.partition(" ")
            sim.write_text(head + "-target " + triple + "-simulator " + tail)
        else:
            shutil.copy2(f, sim)
        f.unlink()
    subprocess.run(["codesign", "-f", "-s", "-", str(dst)], check=True, capture_output=True)
    libs.append({**device, "LibraryIdentifier": ident, "SupportedPlatformVariant": "simulator"})
    (xcf / "Info.plist").write_bytes(plistlib.dumps(info))
    print(f"{xcf.name}: {ident} added")


def main() -> None:
    staged = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "app/Staged"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / ".work/simulator"
    (out / "lib").mkdir(parents=True, exist_ok=True)
    for a in sorted((staged / "lib").glob("*.a")):
        members, changed = patch_archive(a, out / "lib" / a.name)
        print(f"{a.name}: {members} members, {changed} rewritten")
    for xcf in sorted(staged.glob("*.xcframework")):
        simulator_slice(xcf)


if __name__ == "__main__":
    main()
