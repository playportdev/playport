# SPDX-License-Identifier: GPL-3.0-or-later
"""The network databases ws2_32 reads (PLA-116): Wine's dlls/ws2_32/{hosts,
networks,protocol,services} recorded and staged as Runtime/etc, shipped in both
variants, copied into the prefix's drivers/etc by wine_host.c seed_etc, and the
Tcpip\\Parameters DataBasePath wine.inf writes in the committed system.reg seed."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_prefix_registry import sections

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("etc_stage", REPO / "build/stages/stage-artifacts.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class NetworkDatabases(unittest.TestCase):
    def test_record_takes_the_four_files_wine_inf_installs_from_the_wine_pin(self):
        self.assertEqual(stage.ETC, ["hosts", "networks", "protocol", "services"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            roots = {k: root / k for k in stage.ROOTS}
            files = [("unix", f"wine/dlls/ws2_32/{n}") for n in stage.ETC] + [
                ("unix", f"wine/fonts/{n}") for n in stage.FONTS] + [
                ("fex-wow64", "libwow64fex.dll"), ("vulkan-pe", "i386-windows/d3d9.dll"),
                ("session", "playport-session.exe"), ("session", "playport-url-opener.exe"),
                ("steamclient", "steamclient64.dll"), ("steamclient", "steamclient.dll"),
                ("registry", "system.reg"), ("registry", "user.reg"), ("ca-bundle", "cacert.pem"),
                ("wine-mono", "bin/libmono-2.0-x86_64.dll")]
            for key, name in files:
                p = roots[key] / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(name.encode())
            manifest = root / "artifacts.tsv"
            with patch.multiple(stage, REPO=root, ROOTS=roots, MANIFEST=manifest,
                                NLS=[], SXS=[], LINK=[], SOURCES=[], VULKAN_PE=[], VULKAN_PE_I386=[], VULKAN_LOADER=[], STEAMAPI=[], GAPS=[]), \
                 patch.object(stage, "reference_names", return_value=[]), \
                 patch.object(stage, "selection", return_value=[]), \
                 patch.object(stage, "production", return_value={}):
                stage.record()
            rows = [l.split("\t") for l in manifest.read_text().splitlines() if l and not l.startswith("#")]
            etc = {r[1]: r for r in rows if r[6] == "etc"}
            self.assertEqual(set(etc), {f"Runtime/etc/{n}" for n in stage.ETC})
            for dest, (kind, _, size, digest, key, source, _) in etc.items():
                self.assertEqual((kind, key, source), ("resource", "unix", "wine/dlls/ws2_32/" + Path(dest).name))
                self.assertEqual((size, digest), (str((roots[key] / source).stat().st_size),
                                                  stage.sha256(roots[key] / source)))

    def test_committed_manifest_ships_them_in_both_variants(self):
        rows = [l.split("\t") for l in (REPO / "app/artifacts.tsv").read_text().splitlines()
                if l and not l.startswith("#")]
        self.assertEqual({r[1] for r in rows if r[6] == "etc"}, {f"Runtime/etc/{n}" for n in stage.ETC})
        text = (REPO / "app/xtool.yml").read_text()
        self.assertIn("  - Sources/S1Probe/Runtime/etc\n", text)
        self.assertIn("  - Runtime/etc\n", stage.release_xtool_yml(text))
        self.assertIn('"etc"', (REPO / "build/verify-ipa.py").read_text())

    def test_system_seed_points_ws2_32_at_the_prefix_drivers_etc(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        marked, values = system["System\\\\CurrentControlSet\\\\Services\\\\Tcpip\\\\Parameters"]
        self.assertTrue(marked)
        self.assertIn('"DataBasePath"="C:\\\\windows\\\\system32\\\\drivers\\\\etc"', values)

    def test_wine_host_copies_each_file_before_the_wineserver_starts(self):
        src = (REPO / "app/Sources/WineHost/wine_host.c").read_text()
        self.assertIn('static const char *const files[] = { "hosts", "networks", "protocol", "services" };', src)
        self.assertIn("/drive_c/windows/system32/drivers/etc", src)
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL", src)   # a prefix's own hosts stays
        start = src.index("    seed_profile();\n")
        self.assertLess(src.index("    seed_etc();\n", start), src.index("pthread_create(&g_server_thread", start))


if __name__ == "__main__":
    unittest.main()
