# SPDX-License-Identifier: GPL-3.0-or-later
"""Playport's Steam client answers every slot as MSVC's callers expect (decision 0115).

Builds steamclient.dll (i386) and steamclient64.dll (x86-64) as build/stages/steamclient.sh
does, and app/SteamClientShim/tests/abi_probe.c for each, and runs the probe under desktop
Wine: every slot of every interface version is called with `this` in ECX/RCX and its stack
arguments, and must pop exactly them (i386 thiscall), give a class back through the hidden
pointer and keep the x87 stack balanced. Skipped without llvm-mingw (pp setup) or wine."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "build"))
import inputs  # noqa: E402

SHIM = REPO / "app/SteamClientShim"


class SteamClientABI(unittest.TestCase):
    def setUp(self):
        mingw = inputs.get("LLVM_MINGW")
        if not mingw or not (Path(mingw) / "bin/i686-w64-mingw32-clang").exists():
            self.skipTest("no llvm-mingw (pp setup)")
        if not shutil.which("wine"):
            self.skipTest("no desktop wine")
        self.mingw = Path(mingw)
        (inputs.BUILD / "tmp").mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=inputs.BUILD / "tmp")
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        subprocess.run(["wineserver", "-k"], env=self.env(), capture_output=True)
        self.tmp.cleanup()

    def env(self):
        return dict(os.environ, WINEPREFIX=str(self.dir / "prefix"), WINEDEBUG="-all", DISPLAY="", WAYLAND_DISPLAY="",
                    WINEDLLOVERRIDES="mscoree,mshtml,winemenubuilder.exe=d")

    def build(self, arch, entry, name, *libs):
        cc = str(self.mingw / f"bin/{arch}-w64-mingw32-clang")
        subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-Werror", "-ffreestanding", "-fno-builtin", "-nostdlib", "-shared",
                        f"-Wl,--entry,{entry}", "-o", str(self.dir / name), str(SHIM / "steamclient.c"), "-lkernel32", *libs],
                       check=True)
        subprocess.run([cc, "-O1", "-Wall", "-Wextra", "-Werror", "-o", str(self.dir / f"probe-{arch}.exe"),
                        str(SHIM / "tests/abi_probe.c")], check=True)
        return f"probe-{arch}.exe"

    def probe(self, exe, dll):
        out = subprocess.run(["wine", exe, dll], cwd=self.dir, env=self.env(), capture_output=True, text=True, timeout=600)
        lines = [l for l in out.stdout.splitlines() if l.startswith(("ok ", "FAIL")) or "failures" in l]
        self.assertEqual(out.returncode, 0, "\n".join(lines) or out.stderr[-2000:])
        self.assertTrue(lines and lines[-1].startswith("ok "), out.stdout[-2000:])

    def test_i386_slots_pop_their_arguments(self):
        cc = str(self.mingw / "bin/i686-w64-mingw32-clang")
        builtins = subprocess.run([cc, "-print-libgcc-file-name"], capture_output=True, text=True, check=True).stdout.strip()
        exe = self.build("i686", "_DllEntry@12", "steamclient.dll", builtins)
        self.probe(exe, "steamclient.dll")

    def test_x86_64_slots(self):
        exe = self.build("x86_64", "DllEntry", "steamclient64.dll")
        self.probe(exe, "steamclient64.dll")


if __name__ == "__main__":
    unittest.main()
