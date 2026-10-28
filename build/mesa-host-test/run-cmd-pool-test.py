#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Link a private-state regression to the actual mock driver's archives.

    python3 build/mesa-host-test/run-cmd-pool-test.py HOSTTEST_BUILD [TEST]

TEST is the test's name, kk-cmd-pool-test (the default) or kk-residency-test.

Run after run.sh has built the mock, or rebuild its driver with ninja first.
Uses the build's own compile/link flags; no independently modelled pool.
"""
import json
import pathlib
import shlex
import subprocess
import sys

build = pathlib.Path(sys.argv[1]).resolve()
test = sys.argv[2] if len(sys.argv) > 2 else 'kk-cmd-pool-test'
here = pathlib.Path(__file__).resolve().parent
entry = next(e for e in json.loads((build / 'compile_commands.json').read_text())
             if e['file'].endswith('/kk_cmd_pool.c'))
args = shlex.split(entry['command'])
args = args[:args.index('-MD')]
obj = build.parent / f'{test}.o'
subprocess.run(args + ['-UNDEBUG', '-c', str(here / f'{test}.c'),
                      '-o', str(obj)], cwd=build, check=True)
commands = subprocess.check_output(
    ['ninja', '-C', str(build), '-t', 'commands',
     'src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so'], text=True)
link = shlex.split(commands.splitlines()[-1])
link.remove('-shared')
link = [a for a in link if not a.startswith('-Wl,-soname,')]
exe = build.parent / test
link[link.index('-o') + 1] = str(exe)
subprocess.run(link + [str(obj)], cwd=build, check=True)
subprocess.run([str(exe)], check=True, timeout=30)
