#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Decode/allocate/emit a closed MOV EAX,[EBX] using the checked-load test seam.

Native non-EC context only. Compiles complete real Frontend and MemoryOps TUs
with ABI-neutral test macros, ahead of the real FEX archives. No FEX method is
replaced. Sparse separated backing and compiled checks execute in the optional
hash-locked ARM simulator; no hook emulates a memory operation or helper call.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess

from arm_simulator_audit import ROOT, check_dependency, require
from scalar_arm_audit import audit, build

SOURCE = ROOT / "build/guest32"
OUTPUT = ROOT / ".work/guest32/scalar-lowering"


def emit(build_dir, helper, name, sanitize):
    cache = (build_dir / "CMakeCache.txt").read_text().splitlines()
    for value in ("ENABLE_FEX_ALLOCATOR:BOOL=OFF", "ENABLE_X86_HOST_DEBUG:BOOL=ON", "ENABLE_ASSERTIONS:BOOL=ON"):
        require(value in cache, f"native build requires {value}")
    entries = json.loads((build_dir / "compile_commands.json").read_text())
    entry = next(e for e in entries if e["file"].endswith("/Interface/Core/Frontend.cpp"))
    flags = shlex.split(entry["command"])
    flags = flags[:flags.index("-o")]
    require(not any("FEX_IOS_HOST" in flag or "ARCHITECTURE_arm64ec" in flag for flag in flags), "native non-EC layout required")
    libraries = [build_dir / "FEXCore/Source" / f"lib{lib}.a" for lib in ("FEXCore", "FEXCore_Base", "JemallocDummy")]
    libraries += [build_dir / "External/cephes/libcephes_128bit.a", build_dir / "External/SoftFloat-3e/libsoftfloat_3e.a"]
    instrumentation = ["-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"] if sanitize else []
    flags += instrumentation
    objects = []
    for suffix, macro in (("Frontend.cpp", "FEX_TEST_DECODER_BYTE_SOURCE"), ("JIT/MemoryOps.cpp", "FEX_TEST_CHECKED_SCALAR_LOAD")):
        unit = Path(next(e["file"] for e in entries if e["file"].endswith("/Interface/Core/" + suffix)))
        require(unit.resolve().is_relative_to(ROOT / ".work"), "source must stay in .work")
        require(macro in unit.read_text(), f"missing test seam: {macro}")
        print(f"sha256 {hashlib.sha256(unit.read_bytes()).hexdigest()} {unit.relative_to(ROOT)}", flush=True)
        obj = OUTPUT / f"{name}-{unit.stem}.o"
        subprocess.run([*flags, "-D" + macro + "=1", "-c", str(unit), "-o", str(obj)], cwd=entry["directory"], check=True, timeout=120)
        objects.append(obj)
    memory = OUTPUT / f"{name}-guest32.o"
    subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", *instrumentation,
                    "-c", str(SOURCE / "guest32.c"), "-o", str(memory)], check=True, timeout=60)
    objects.append(memory)
    for path in (SOURCE / "scalar_lowering_test.cpp", *libraries):
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}", flush=True)
    executable = OUTPUT / name
    subprocess.run([*flags, "-UNDEBUG", "-Werror", str(SOURCE / "scalar_lowering_test.cpp"), *map(str, objects),
                    "-Wl,--gc-sections", "-Wl,--start-group", *map(str, libraries), "-Wl,--end-group",
                    "-lfmt", "-lxxhash", "-o", str(executable)], cwd=entry["directory"], check=True, timeout=120)
    exported = OUTPUT / f"{name}.jsonl"
    subprocess.run([str(executable), hex(helper), str(exported)], check=True, timeout=60)
    blocks = [json.loads(line) for line in exported.read_text().splitlines()]
    require([b["pc"] for b in blocks] == [0x400fff, 0x900fff, 0xffff0fff], "decoded load export census")
    return blocks


def controls(elf, block):
    # Mutate private exported code, never the tree or shipped emitter. Locate
    # exact A64 fields, require unique sites, then check observable failures.
    original = bytes.fromhex(block["code"])
    words = list(struct.unpack("<" + "I" * (len(original) // 4), original))
    mutations = [
        ("address-register", lambda w: w == 0xaa0603e1, lambda w: 0xaa0503e1, "emitted helper arguments mismatch"),
        ("access-width", lambda w: w == 0xd2800082, lambda w: 0xd2800042, "emitted helper arguments mismatch"),
        ("status-branch", lambda w: w & 0xff00001f == 0xb4000000, lambda w: 0xd503201f,
         "caller rejection/continuation/guest-PC mismatch"),
        ("destination", lambda w: w == 0x2a0303e4, lambda w: 0x2a0303e5, "live FEX GPR mismatch"),
        ("fault-pc", lambda w: w == 0x5281ffe0, lambda w: 0x5281ffc0,
         "caller rejection/continuation/guest-PC mismatch"),
    ]
    for name, matches, replace, reason in mutations:
        sites = [i for i, word in enumerate(words) if matches(word)]
        require(len(sites) == 1, f"non-unique lowering mutation {name}: {sites}")
        changed = bytearray(original)
        struct.pack_into("<I", changed, sites[0] * 4, replace(words[sites[0]]))
        mutant = copy.deepcopy(block)
        mutant["code"] = changed.hex()
        try:
            audit(elf, call_block=mutant)
        except RuntimeError as error:
            require(reason in str(error), f"wrong lowering corruption failure: {error}")
        else:
            raise RuntimeError(f"accepted lowering corruption: {name}")
        print(f"PASS lowering corruption {name}: {reason}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--sanitize", action="store_true", help="instrument real test TUs/frontend/memory handlers/g32, not archives or simulator")
    args = parser.parse_args()
    build_dir = args.build.resolve()
    require(build_dir.is_relative_to(ROOT / ".work"), "build must stay in .work")
    uc = check_dependency()
    library = Path(uc.__file__).parent / "lib/libunicorn.so.2"
    print(f"simulator {uc.__version__}; sha256 {hashlib.sha256(library.read_bytes()).hexdigest()}", flush=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for filename in ("scalar_lowering_audit.py", "scalar_arm_audit.py", "scalar_access.c", "scalar_access.h", "guest32.c", "guest32.h",
                     "native_audit_adapter.h", "scalar_arm_fixture.c", "scalar_call_clobber.S"):
        path = SOURCE / filename
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}", flush=True)
    # Existing non-test archives need not rebuild: test objects precede them.
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "FEXCore", "FEXCore_Base", "JemallocDummy",
                    "cephes_128bit", "softfloat_3e", "-j", "6"], check=True, timeout=600)
    for stress in (False, True):
        name = "clobber" if stress else "ordinary"
        elf = build("lowering-" + name, clobber=stress)
        print(f"ELF sha256 {hashlib.sha256(elf.read_bytes()).hexdigest()}", flush=True)
        symbols = {line.split()[2]: int(line.split()[0], 16) for line in subprocess.check_output(
            ["llvm-nm", "--defined-only", str(elf)], text=True).splitlines()}
        blocks = emit(build_dir, symbols["audit_clobber" if stress else "g32_scalar_access"],
                      name + ("-sanitized" if args.sanitize else "-optimized"), args.sanitize)
        for block in blocks:
            require(audit(elf, call_block=block) == 1065, "decoded load simulation census")
        print(f"PASS {name}: 3195 decoded checked loads, 3 PCs, complete-width rejection and live-state preservation", flush=True)
        if stress:
            controls(elf, blocks[0])
    print("PASS closed checked-load lowering; NOT general provenance, guest fault delivery, ARM64EC or phone execution", flush=True)


if __name__ == "__main__":
    main()
