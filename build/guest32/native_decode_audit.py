#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Audit real FEX decoding, IR/RA and register-only or raw scalar ARM emission.

Requires the native configuration documented in the allocator evidence. Only
Frontend.cpp alone enables its ABI-neutral test byte-source seam; the test
supplies that adapter. No platform layout macro or FEX method is replaced, and
all generated outputs stay in .work. This is not an app entry point.
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
    parser.add_argument("--sanitize", action="store_true",
                        help="ASan/UBSan for audit, frontend and g32 (other FEX archives uninstrumented)")
    parser.add_argument("--ir", action="store_true",
                        help="audit register-only decode-to-IR before optimization/RA; no execution")
    parser.add_argument("--allocate", action="store_true",
                        help="audit register-only IR through the default optimizer/RA pipeline; implies --ir")
    parser.add_argument("--emit", action="store_true",
                        help="audit real ARM emission and register/exit semantics offline; implies --allocate")
    parser.add_argument("--simulate", action="store_true",
                        help="execute exported ARM blocks in the optional host simulator; implies --emit")
    parser.add_argument("--memory-ir", action="store_true",
                        help="audit scalar guest-address IR before optimization/RA; no JIT execution")
    parser.add_argument("--memory-allocate", action="store_true",
                        help="audit scalar guest-address IR through optimization/RA; implies --memory-ir")
    parser.add_argument("--memory-simulate", action="store_true",
                        help="audit raw scalar ARM emission in the optional simulator; implies --memory-allocate; NOT checked access")
    args = parser.parse_args()
    args.memory_allocate = args.memory_allocate or args.memory_simulate
    args.memory_ir = args.memory_ir or args.memory_allocate
    if args.memory_ir and (args.ir or args.allocate or args.emit or args.simulate):
        parser.error("memory modes are separate from the register-only gates")
    args.emit = args.emit or args.simulate
    args.allocate = args.allocate or args.emit
    args.ir = args.ir or args.allocate
    build = args.build.resolve()
    if not build.is_relative_to(ROOT / ".work"):
        parser.error("build must be inside the repository's .work directory")
    cache = (build / "CMakeCache.txt").read_text().splitlines()
    for required in ("ENABLE_FEX_ALLOCATOR:BOOL=OFF", "ENABLE_X86_HOST_DEBUG:BOOL=ON",
                     "ENABLE_ASSERTIONS:BOOL=ON"):
        if required not in cache:
            parser.error(f"requires {required}")
    entries = json.loads((build / "compile_commands.json").read_text())
    entry = next(e for e in entries if e["file"].endswith("/Interface/Core/Frontend.cpp"))
    frontend = Path(entry["file"]).resolve()
    if not frontend.is_relative_to(ROOT / ".work"):
        parser.error("frontend source must be inside .work")
    flags = shlex.split(entry["command"])
    flags = flags[:flags.index("-o")]
    if any("FEX_IOS_HOST" in flag for flag in flags):
        parser.error("requires a native non-iOS base build")
    if 'FEXTestDecoderByteSource' not in frontend.read_text():
        parser.error("requires the series-applied decoder byte-source test seam")
    if args.simulate or args.memory_simulate:
        from arm_simulator_audit import check_dependency
        check_dependency()
    audit = ("separated-memory-emission" if args.memory_simulate else
             "separated-memory-ra" if args.memory_allocate else
             "separated-memory-ir" if args.memory_ir else
             "separated-execution" if args.simulate else
             "separated-emission" if args.emit else
             "separated-ra" if args.allocate else
             "separated-ir" if args.ir else "separated-decoder")
    output = ROOT / ".work/guest32" / audit / ("sanitized" if args.sanitize else "optimized")
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cmake", "--build", str(build), "--target", "FEXCore",
                    "FEXCore_Base", "JemallocDummy", "cephes_128bit", "softfloat_3e",
                    "-j", "6"], check=True, timeout=600)
    test = ROOT / "build/guest32" / ("native_memory_ir_test.cpp" if args.memory_ir else
                                     "native_ir_test.cpp" if args.ir else "native_decode_test.cpp")
    memory = ROOT / "build/guest32/guest32.c"
    scalar = ROOT / "build/guest32/scalar_access.c"
    libraries = [build / "FEXCore/Source" / f"lib{name}.a"
                 for name in ("FEXCore", "FEXCore_Base", "JemallocDummy")]
    libraries += [build / "External/cephes/libcephes_128bit.a",
                  build / "External/SoftFloat-3e/libsoftfloat_3e.a"]
    adapter = ROOT / "build/guest32/native_audit_adapter.h"
    extra_sources = [ROOT / "build/guest32/native_code_oracle.h"] if args.emit else []
    if args.memory_ir:
        extra_sources += [scalar, ROOT / "build/guest32/scalar_access.h"]
    if args.memory_allocate:
        extra_sources += [ROOT / "build/guest32/native_context_ir_oracle.h"]
    if args.memory_simulate:
        extra_sources += [ROOT / "build/guest32/native_memory_export.h",
                          ROOT / "build/guest32/arm_memory_simulator_audit.py"]
    if args.simulate or args.memory_simulate:
        extra_sources += [ROOT / "build/guest32/arm_simulator_audit.py",
                          ROOT / "build/guest32/arm_simulator_requirements.txt"]
    for path in [test, adapter, memory, frontend, *extra_sources, *libraries]:
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}",
              flush=True)
    instrumentation = ["-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"] if args.sanitize else []
    flags += instrumentation
    if args.allocate or args.memory_allocate:
        flags += ["-DFEX_AUDIT_ALLOCATE=1"]
    if args.emit or args.memory_simulate:
        flags += ["-DFEX_AUDIT_EMIT=1"]
    if args.simulate or args.memory_simulate:
        flags += ["-DFEX_AUDIT_EXPORT=1"]
    frontend_object = output / "frontend.o"
    memory_object = output / "guest32.o"
    # Compile the complete series-applied frontend with ONLY the test seam on.
    # All context/thread layout flags match the archives and the test TU.
    # The object precedes libFEXCore so the archive's ordinary frontend is unused.
    executable = output / ("memory-ir-test" if args.memory_ir else "ir-test" if args.ir else "decode-test")
    commands = [
        [*flags, "-DFEX_TEST_DECODER_BYTE_SOURCE=1", "-c", str(frontend), "-o", str(frontend_object)],
        ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", *instrumentation,
         "-c", str(memory), "-o", str(memory_object)],
        # Exceptions are local to the memory inspector's negative controls;
        # no exception unwinds through FEX, whose build flags remain unchanged.
        [*flags, *(["-fexceptions"] if args.memory_ir else []), "-UNDEBUG", "-Werror",
         str(test), str(frontend_object), str(memory_object),
         *([str(output / "scalar_access.o")] if args.memory_ir else []),
         "-Wl,--gc-sections", "-Wl,--start-group", *map(str, libraries),
         "-Wl,--end-group", "-lfmt", "-lxxhash", "-o", str(executable)],
    ]
    if args.memory_ir:
        commands.insert(2, ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", *instrumentation,
                            "-c", str(scalar), "-o", str(output / "scalar_access.o")])
    for command in commands:
        subprocess.run(command, cwd=entry["directory"], check=True, timeout=120)
    exported = output / "blocks.jsonl"
    subprocess.run([str(executable), *([str(exported)] if args.simulate or args.memory_simulate else [])], check=True, timeout=60)
    if args.memory_simulate:
        from arm_memory_simulator_audit import audit_file
        audit_file(exported)
    if args.simulate:
        from arm_simulator_audit import audit_file
        audit_file(exported)


if __name__ == "__main__":
    main()
