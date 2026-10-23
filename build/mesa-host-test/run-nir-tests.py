#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run focused C/NIR assertions with the mock build's exact compiler settings."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

build = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
commands = json.loads(subprocess.check_output(
    ["ninja", "-C", str(build), "-t", "compdb", "c_COMPILER"]))
libs = ["src/compiler/nir/libnir.a", "src/compiler/libcompiler.a",
        "src/util/libmesa_util.a", "src/util/libmesa_util_clflush.a",
        "src/util/libmesa_util_clflushopt.a", "src/util/libmesa_util_simd.a",
        "src/util/blake3/libblake3.a", "src/c11/impl/libmesa_util_c11.a"]
for name, source in [("kk-experimental-test", "kk_debug.c"),
                     ("kk-nir-merge-ubo-loads-test", "kk_nir_merge_ubo_loads.c")]:
    command = next(c for c in commands if c["file"].endswith("/" + source))
    args = shlex.split(command["command"])
    # Do not replace the driver's own dependency files while compiling tests.
    for flag in ("-MQ", "-MF"):
        if flag in args:
            index = args.index(flag)
            del args[index:index + 2]
    if "-MD" in args:
        args.remove("-MD")
    obj = name + ".o"
    args[args.index("-o") + 1] = obj
    # The original compiler command ends in -c SOURCE.
    args[args.index("-c") + 1] = str(here / (name + ".c"))
    subprocess.run(args, cwd=build, check=True)
    subprocess.run(["c++", "-o", name, obj, command["output"],
                    "-Wl,--start-group", *libs, "-Wl,--end-group",
                    "-lz", "-lunwind", "-lm", "-pthread"], cwd=build, check=True)
    subprocess.run([str(build / name)], check=True)
