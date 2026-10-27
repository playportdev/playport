# SPDX-License-Identifier: GPL-3.0-or-later
"""build/stages/stage-artifacts.py's Wine module selection (decisions 0070, 0071):
the production set from the generated manifests, replacements over Wine's
modules, and the committed record against it."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("selection_stage", REPO / "build/stages/stage-artifacts.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


def manifest(tmp, arch, paths):
    d = Path(tmp)
    (d / f"wine-pe-{arch}-windows.tsv").write_text(
        "".join(f"{p}\t100\t{'0' * 64}\tpe\t0x8664\tIMAGE_FILE_MACHINE_ARM64EC\tyes\n" for p in paths))
    return d


def committed_rows():
    return [l.split("\t") for l in (REPO / "app/artifacts.tsv").read_text().splitlines()
            if l and not l.startswith("#")]


class Production(unittest.TestCase):
    def test_production_excludes_tests_and_winetest_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            gen = manifest(tmp, "i386", [
                "dlls/kernel32/i386-windows/kernel32.dll", "dlls/joy.cpl/i386-windows/joy.cpl",
                "dlls/ntoskrnl.exe/i386-windows/ntoskrnl.exe", "programs/reg/i386-windows/reg.exe",
                "dlls/kernel32/tests/i386-windows/kernel32_test.exe",
                "programs/winetest/i386-windows/winetest.exe", "programs/control/i386-windows/control.exe",
                "programs/winemenubuilder/i386-windows/winemenubuilder.exe",
                "dlls/krnl386.exe16/i386-windows/krnl386.exe16", "dlls/vmm.vxd/i386-windows/vmm.vxd",
                "fonts/tahoma.ttf"])
            idx = stage.production("i386", gen)
        self.assertEqual(set(idx), {"kernel32.dll", "joy.cpl", "ntoskrnl.exe", "reg.exe", "control.exe",
                                    "winemenubuilder.exe", "krnl386.exe16", "vmm.vxd"})
        self.assertEqual(idx["reg.exe"][0], "build-macos/programs/reg/i386-windows/reg.exe")

    def test_production_stops_on_a_case_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            gen = manifest(tmp, "arm64ec", ["dlls/normaliz/arm64ec-windows/normaliz.dll",
                                            "dlls/Normaliz/arm64ec-windows/Normaliz.dll"])
            with self.assertRaises(SystemExit):
                stage.production("arm64ec", gen)


class Selection(unittest.TestCase):
    IDX = {n: (f"build-arm64ec/dlls/{n}/arm64ec-windows/{n}", 1, "0") for n in
           ("normaliz.dll", "ntdll.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "xtajit64.dll", "dbgeng.dll",
            "cmd.exe")}

    def test_arm64ec_takes_every_built_module_plus_replacements(self):
        names = stage.selection("arm64ec", self.IDX, ["Normaliz.dll", "madeira_d3d12.dll", "winemetal.dll"])
        self.assertEqual(names, sorted(["Normaliz.dll", "ntdll.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll",
                                        "xtajit64.dll", "dbgeng.dll", "cmd.exe", "winemetal.dll"]))

    def test_aarch64_takes_every_built_module_plus_replacements(self):
        idx = {n: (f"build-macos/{'programs' if n.endswith('.exe') else 'dlls'}/{n}/aarch64-windows/{n}", 1, "0")
               for n in ("reg.exe", "winedbg.exe", "advapi32.dll", "wow64.dll", "d3d11.dll", "dbgeng.dll",
                         "normaliz.dll")}
        names = stage.selection("aarch64", idx, ["Normaliz.dll", "xtajit.dll", "madeira_test.exe"])
        self.assertEqual(names, sorted(["reg.exe", "winedbg.exe", "advapi32.dll", "wow64.dll", "d3d11.dll",
                                        "dbgeng.dll", "Normaliz.dll", "dxgi.dll", "winemetal.dll"]))


class Record(unittest.TestCase):
    def test_record_keeps_replacement_providers_and_rejects_duplicate_destinations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            roots = {k: root / k for k in stage.ROOTS}
            gen = root / "generated"
            gen.mkdir()
            built = {"arm64ec": ["xtajit64.dll", "ntdll.dll", "d3d11.dll", "dbgeng.dll"], "aarch64": ["wow64.dll", "wow64win.dll"],
                     "i386": ["kernel32.dll"]}
            for arch, names in built.items():
                tree = "build-arm64ec" if arch == "arm64ec" else "build-macos"
                lines = []
                for n in names:
                    rel = f"dlls/{n[:-4]}/{arch}-windows/{n}"
                    p = roots["wine-build"] / tree / rel
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_bytes(f"wine {arch} {n}".encode())
                    lines.append(f"{rel}\t{p.stat().st_size}\t{stage.sha256(p)}\tpe\n")
                (gen / f"wine-pe-{arch}-windows.tsv").write_text("".join(lines))
            for key, name in [("fex", "libarm64ecfex.dll"), ("fex-wow64", "libwow64fex.dll"),
                              ("dxmt-pe", "arm64ec-windows/d3d11.dll"), ("dxmt-pe", "arm64ec-windows/dxgi.dll"),
                              ("dxmt-pe", "arm64ec-windows/d3d10core.dll"),
                              ("dxmt-pe", "arm64ec-windows/winemetal.dll"),
                              ("dxmt-pe", "aarch64-windows/d3d11.dll"), ("dxmt-pe", "aarch64-windows/dxgi.dll"),
                              ("dxmt-pe", "aarch64-windows/winemetal.dll"), ("vulkan-pe", "i386-windows/d3d9.dll"),
                              ("session", "playport-session.exe"), ("session", "playport-url-opener.exe"),
                ("steamclient", "steamclient64.dll"), ("steamclient", "steamclient.dll"),
                              ("registry", "system.reg"), ("registry", "user.reg"), ("ca-bundle", "cacert.pem"),
                              ("wine-mono", "bin/libmono-2.0-x86_64.dll")]:
                p = roots[key] / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(f"{key} {name}".encode())
            out = root / "artifacts.tsv"
            common = dict(REPO=root, ROOTS=roots, MANIFEST=out, GENERATED=gen, NLS=[], FONTS=[], ETC=[], SXS=[], LINK=[], SOURCES=[],
                          VULKAN_PE=[], VULKAN_PE_I386=[], VULKAN_LOADER=[], STEAMAPI=[], GAPS=[])
            with patch.multiple(stage, **common), patch.object(stage, "reference_names", return_value=[]):
                stage.record()
            rows = {r[1]: r for r in (l.split("\t") for l in out.read_text().splitlines()
                                      if l and not l.startswith("#"))}
            prov = {dest: r[6] for dest, r in rows.items()}
            self.assertEqual(prov["Runtime/arm64ec-windows/xtajit64.dll"], "P1-de")
            self.assertEqual(prov["Runtime/arm64ec-windows/ntdll.dll"], "P2-ec")
            self.assertEqual(prov["Runtime/arm64ec-windows/d3d11.dll"], "P5-dxmt-pe")
            self.assertEqual(prov["Runtime/arm64ec-windows/dbgeng.dll"], "P2")
            self.assertEqual(prov["Runtime/i386-windows/kernel32.dll"], "P2")
            d3d11 = rows["Runtime/arm64ec-windows/d3d11.dll"]
            self.assertEqual(d3d11[3], stage.sha256(roots["dxmt-pe"] / "arm64ec-windows/d3d11.dll"))
            gaps = [("resource", "Runtime/arm64ec-windows/DBGENG.dll", "duplicate")]
            with patch.multiple(stage, **dict(common, GAPS=gaps)), \
                 patch.object(stage, "reference_names", return_value=[]), self.assertRaises(SystemExit):
                stage.record()


class CommittedRecord(unittest.TestCase):
    """app/artifacts.tsv, as a build records it, against build/generated."""

    def test_every_production_module_is_recorded(self):
        rows = committed_rows()
        for arch in ("arm64ec", "aarch64", "i386"):
            dests = {r[1].lower() for r in rows if r[0] == "resource"}
            missing = [n for n in stage.production(arch) if f"runtime/{arch}-windows/{n}" not in dests]
            self.assertEqual(missing, [], arch)

    def test_no_test_or_left_out_module_and_one_row_per_destination(self):
        rows = committed_rows()
        dests = [r[1].lower() for r in rows]
        self.assertEqual(len(dests), len(set(dests)))
        for r in rows:
            if r[0] != "resource" or r[4] != "wine-build":
                continue
            name = r[1].rsplit("/", 1)[1].lower()
            self.assertNotIn("/tests/", r[5])
            self.assertNotIn(name, stage.NOT_SHIPPED)

    def test_replacements_keep_their_providers(self):
        prov = {r[1]: r[6] for r in committed_rows()}
        self.assertEqual(prov["Runtime/arm64ec-windows/xtajit64.dll"], "P1-de")
        self.assertEqual(prov["Runtime/aarch64-windows/xtajit.dll"], "P1-de")
        self.assertEqual(prov["Runtime/arm64ec-windows/ntdll.dll"], "P2-ec")
        for arch, names in stage.DXMT_PE.items():
            for n in names:
                self.assertEqual(prov[f"Runtime/{arch}-windows/{n}"], "P5-dxmt-pe", n)

    def test_proton_programs_and_16_bit_modules_are_staged(self):
        dests = {r[1].lower() for r in committed_rows()}
        for dest in ("aarch64-windows/winedbg.exe", "aarch64-windows/control.exe",
                     "aarch64-windows/winemenubuilder.exe", "aarch64-windows/wow64.dll",
                     "i386-windows/winedbg.exe", "i386-windows/control.exe", "i386-windows/krnl386.exe16",
                     "i386-windows/vmm.vxd"):
            self.assertIn(f"runtime/{dest}", dests)
        self.assertFalse(any(d.endswith("/winetest.exe") for d in dests))


if __name__ == "__main__":
    unittest.main()
