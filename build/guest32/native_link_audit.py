#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Link/run real native FEX context, allocator and reset hooks; not guest execution.

Requires the series-applied native build documented in the evidence record.
Generated files stay under .work; this is not an app entry point.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="configured native FEX build directory")
    args = parser.parse_args()
    build = args.build.resolve()
    if not build.is_relative_to(ROOT / ".work"):
        parser.error("build must be inside the repository's .work directory")
    cache = (build / "CMakeCache.txt").read_text()
    for required in ("ENABLE_FEX_ALLOCATOR:BOOL=OFF", "ENABLE_X86_HOST_DEBUG:BOOL=ON"):
        if required not in cache.splitlines():
            parser.error(f"requires {required}")
    entries = json.loads((build / "compile_commands.json").read_text())
    entry = next(e for e in entries if e["file"].endswith("/Interface/Core/Core.cpp"))
    flags = shlex.split(entry["command"])
    flags = flags[:flags.index("-o")]
    if any("FEX_IOS_HOST" in flag for flag in flags):
        parser.error("native test must not enable FEX_IOS_HOST")
    output = ROOT / ".work/guest32/native-link-audit"
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cmake", "--build", str(build), "--target", "FEXCore",
                    "FEXCore_Base", "JemallocDummy", "cephes_128bit", "softfloat_3e",
                    "-j", "6"], check=True, timeout=600)
    test = ROOT / "build/guest32/native_link_test.cpp"
    libraries = [build / "FEXCore/Source" / f"lib{name}.a"
                 for name in ("FEXCore", "FEXCore_Base", "JemallocDummy")]
    libraries += [build / "External/cephes/libcephes_128bit.a",
                  build / "External/SoftFloat-3e/libsoftfloat_3e.a"]
    for path in [test, Path(entry["file"]), *libraries]:
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}",
              flush=True)
    binary = output / "native-link-test"
    # Keep the real Core.cpp ABI flags, but turn C assert back on for the test.
    command = [*flags, "-UNDEBUG", str(test), "-Wl,--gc-sections",
               "-Wl,--start-group", *map(str, libraries), "-Wl,--end-group",
               "-lfmt", "-lxxhash", "-o", str(binary)]
    subprocess.run(command, cwd=entry["directory"], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == "__main__":
    main()
