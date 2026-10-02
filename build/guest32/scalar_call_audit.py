#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute a bounded real-FEX spill/call/fill fixture, not decode/IR lowering.

Requires the native FEX build and optional hash-locked ARM simulator. Real FEX
archives emit the caller; real compiled helper checks separated backing. No
runtime switch, upstream edit, simulator-assisted memory operation or phone run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

from arm_simulator_audit import ROOT, check_dependency, require
from scalar_arm_audit import audit, build

OUTPUT = ROOT / ".work/guest32/scalar-call"
SOURCE = ROOT / "build/guest32"


def emit(build_dir, helper, name, sanitize):
    cache = (build_dir / "CMakeCache.txt").read_text().splitlines()
    for value in ("ENABLE_FEX_ALLOCATOR:BOOL=OFF", "ENABLE_X86_HOST_DEBUG:BOOL=ON", "ENABLE_ASSERTIONS:BOOL=ON"):
        require(value in cache, f"native build requires {value}")
    entries = json.loads((build_dir / "compile_commands.json").read_text())
    entry = next(e for e in entries if e["file"].endswith("/Interface/Core/Frontend.cpp"))
    require(Path(entry["file"]).resolve().is_relative_to(ROOT / ".work"), "source must stay in .work")
    flags = shlex.split(entry["command"])
    flags = flags[:flags.index("-o")]
    require(not any("FEX_IOS_HOST" in flag or "ARCHITECTURE_arm64ec" in flag for flag in flags), "native non-EC layout required")
    libraries = [build_dir / "FEXCore/Source" / f"lib{lib}.a" for lib in ("FEXCore", "FEXCore_Base", "JemallocDummy")]
    libraries += [build_dir / "External/cephes/libcephes_128bit.a", build_dir / "External/SoftFloat-3e/libsoftfloat_3e.a"]
    for path in (SOURCE / "scalar_call_emit.cpp", SOURCE / "scalar_call_clobber.S", *libraries):
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}", flush=True)
    executable = OUTPUT / name
    instrumentation = ["-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"] if sanitize else []
    subprocess.run([*flags, *instrumentation, "-UNDEBUG", "-Werror", str(SOURCE / "scalar_call_emit.cpp"),
                    "-Wl,--gc-sections", "-Wl,--start-group", *map(str, libraries), "-Wl,--end-group",
                    "-lfmt", "-lxxhash", "-o", str(executable)], cwd=entry["directory"], check=True, timeout=120)
    exported = OUTPUT / f"{name}.jsonl"
    subprocess.run([str(executable), hex(helper), str(exported)], check=True, timeout=60)
    blocks = [json.loads(line) for line in exported.read_text().splitlines()]
    require([block["mutation"] for block in blocks] == list(range(8)), "caller export census")
    return blocks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--sanitize", action="store_true", help="instrument C++ fixture, not FEX archives or ARM simulator")
    args = parser.parse_args()
    build_dir = args.build.resolve()
    require(build_dir.is_relative_to(ROOT / ".work"), "build must stay in .work")
    uc = check_dependency()
    library = Path(uc.__file__).parent / "lib/libunicorn.so.2"
    print(f"simulator {uc.__version__}; sha256 {hashlib.sha256(library.read_bytes()).hexdigest()}", flush=True)
    for filename in ("scalar_access.c", "scalar_access.h", "guest32.c", "guest32.h", "scalar_arm_fixture.c",
                     "scalar_arm_audit.py", "scalar_call_audit.py"):
        path = SOURCE / filename
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}", flush=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "FEXCore", "FEXCore_Base", "JemallocDummy",
                    "cephes_128bit", "softfloat_3e", "-j", "6"], check=True, timeout=600)
    for stress in (False, True):
        name = "clobber" if stress else "ordinary"
        elf = build(f"caller-{name}", clobber=stress)
        print(f"ELF sha256 {hashlib.sha256(elf.read_bytes()).hexdigest()}", flush=True)
        symbols = {line.split()[2]: int(line.split()[0], 16) for line in subprocess.check_output(
            ["llvm-nm", "--defined-only", str(elf)], text=True).splitlines()}
        target = symbols["audit_clobber" if stress else "g32_scalar_access"]
        blocks = emit(build_dir, target, name + ("-sanitized" if args.sanitize else "-optimized"), args.sanitize)
        audit(elf, call_block=blocks[0])
        print(f"PASS {name}: 6381 real emitted calls preserve live FEX GPR/SIMD/NZCV state", flush=True)
        if stress:
            reasons = {1: "live FEX GPR mismatch", 2: "live FEX GPR mismatch", 3: "live FEX SIMD mismatch",
                       4: "live FEX GPR mismatch", 5: "live FEX NZCV mismatch",
                       6: "caller rejection/continuation/guest-PC mismatch", 7: "caller rejection/continuation/guest-PC mismatch"}
            for block in blocks[1:]:
                try:
                    audit(elf, call_block=block)
                except RuntimeError as error:
                    require(reasons[block["mutation"]] in str(error), f"wrong corruption failure: {error}")
                else:
                    raise RuntimeError("caller corruption unexpectedly accepted")
                print(f"PASS caller corruption {block['mutation']}: {reasons[block['mutation']]}", flush=True)
    print("PASS checked scalar call ABI fixture; NOT FEX IR lowering, ARM64EC, fault delivery or phone execution", flush=True)


if __name__ == "__main__":
    main()
