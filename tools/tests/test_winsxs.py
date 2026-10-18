# SPDX-License-Identifier: GPL-3.0-or-later
"""Wine's side-by-side assemblies (PLA-113): the WINE_MANIFEST manifests wineboot
installs into C:\\windows\\winsxs, recorded and staged as Runtime/winsxs, shipped in
both variants, and installed into the prefix by wine_host.c link_winsxs."""
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sxs_stage", REPO / "build/stages/stage-artifacts.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class WinSxS(unittest.TestCase):
    def test_list_is_every_wine_manifest_resource_of_the_wine_pin(self):
        dlls = stage.ROOTS["unix"] / "wine/dlls"
        if not dlls.is_dir():
            self.skipTest(f"no Wine tree at {dlls}")
        found = set()
        for rc in dlls.glob("*/*.rc"):
            for m in re.finditer(r"^WINE_MANIFEST\w*\s+(?:24|RT_MANIFEST)\s+(\S+)", rc.read_text(errors="replace"), re.M):
                found.add((rc.parent.name, m.group(1)))
        self.assertEqual(set(stage.SXS), found)

    def test_record_takes_the_manifests_from_the_wine_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            roots = {k: root / k for k in stage.ROOTS}
            files = [("unix", f"wine/dlls/{m}/{n}") for m, n in stage.SXS] + [
                ("unix", f"wine/fonts/{n}") for n in stage.FONTS] + [
                ("unix", f"wine/dlls/ws2_32/{n}") for n in stage.ETC] + [
                ("fex-wow64", "libwow64fex.dll"), ("vulkan-pe", "i386-windows/d3d9.dll"),
                ("session", "playport-session.exe"), ("session", "playport-url-opener.exe"),
                ("steamclient", "steamclient64.dll"),
                ("registry", "system.reg"), ("registry", "user.reg"), ("ca-bundle", "cacert.pem"),
                ("wine-mono", "bin/libmono-2.0-x86_64.dll")]
            for key, name in files:
                p = roots[key] / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(name.encode())
            manifest = root / "artifacts.tsv"
            with patch.multiple(stage, REPO=root, ROOTS=roots, MANIFEST=manifest,
                                NLS=[], LINK=[], SOURCES=[], VULKAN_PE=[], VULKAN_PE_I386=[], STEAMAPI=[], GAPS=[]), \
                 patch.object(stage, "reference_names", return_value=[]), \
                 patch.object(stage, "selection", return_value=[]), \
                 patch.object(stage, "production", return_value={}):
                stage.record()
            rows = [l.split("\t") for l in manifest.read_text().splitlines() if l and not l.startswith("#")]
            sxs = {r[1]: r for r in rows if r[6] == "winsxs"}
            self.assertEqual(set(sxs), {f"Runtime/winsxs/{m}/{n}" for m, n in stage.SXS})
            for dest, (kind, _, size, digest, key, source, _) in sxs.items():
                self.assertEqual((kind, key), ("resource", "unix"))
                self.assertEqual(source, "wine/dlls/" + dest.removeprefix("Runtime/winsxs/"))
                self.assertEqual(digest, stage.sha256(roots[key] / source))

    def test_committed_manifest_ships_them_in_both_variants_with_their_modules(self):
        rows = [l.split("\t") for l in (REPO / "app/artifacts.tsv").read_text().splitlines()
                if l and not l.startswith("#")]
        self.assertEqual({r[1] for r in rows if r[6] == "winsxs"},
                         {f"Runtime/winsxs/{m}/{n}" for m, n in stage.SXS})
        # link_winsxs links each module from both sets it installs for.
        dests = {r[1].lower() for r in rows if r[0] == "resource"}
        for module, _ in stage.SXS:
            for pe in ("i386", "arm64ec"):
                self.assertIn(f"runtime/{pe}-windows/{module}.dll", dests)
        text = (REPO / "app/xtool.yml").read_text()
        self.assertIn("  - Sources/S1Probe/Runtime/winsxs\n", text)
        self.assertIn("  - Runtime/winsxs\n", stage.release_xtool_yml(text))
        self.assertIn('"winsxs"', (REPO / "build/verify-ipa.py").read_text())

    def test_wine_host_installs_them_before_the_session_root_starts(self):
        src = (REPO / "app/Sources/WineHost/wine_host.c").read_text()
        self.assertIn('{ { "x86", "i386" }, { "arm64", "arm64ec" } }', src)
        self.assertIn("_none_deadbeef", src)
        start = src.index("int wine_host_session_start(")
        self.assertLess(src.index("    link_winsxs();\n", start), src.index("start_guest()", start))


if __name__ == "__main__":
    unittest.main()
