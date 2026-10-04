# SPDX-License-Identifier: GPL-3.0-or-later
"""Wine-pin fallback fonts: record, staging, packaging and attribution."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("font_stage", REPO / "build/stages/stage-artifacts.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class Fonts(unittest.TestCase):
    def test_record_includes_both_wine_pin_faces(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            roots = {k: root / k for k in stage.ROOTS}
            # Exercise record itself; all unrelated inputs are inert placeholders.
            files = [("unix", f"wine/fonts/{n}") for n in stage.FONTS] + [
                ("fex-wow64", "libwow64fex.dll"),
                ("vulkan-pe", "i386-windows/d3d9.dll"),
                ("session", "playport-session.exe"),
                ("registry", "system.reg"), ("registry", "user.reg")]
            for key, name in files:
                p = roots[key] / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(name.encode())
            manifest = root / "artifacts.tsv"
            with patch.multiple(stage, REPO=root, ROOTS=roots, MANIFEST=manifest,
                                NLS=[], LINK=[], SOURCES=[], VULKAN_PE=[], STEAMAPI=[], GAPS=[],
                                EXTRA_PE={"arm64ec": [], "aarch64": []}), \
                 patch.object(stage, "reference_names", return_value=[]), \
                 patch.object(stage, "pe_index", return_value={}):
                stage.record()
            rows = [l.split("\t") for l in manifest.read_text().splitlines() if l and not l.startswith("#")]
            fonts = [r for r in rows if r[6] == "fonts"]
            self.assertEqual({r[1] for r in fonts}, {"Runtime/fonts/tahoma.ttf", "Runtime/fonts/tahomabd.ttf"})
            for kind, dest, size, digest, key, source, provenance in fonts:
                self.assertEqual((kind, key, source), ("resource", "unix", "wine/fonts/" + Path(dest).name))
                p = roots[key] / source
                self.assertEqual((size, digest), (str(p.stat().st_size), stage.sha256(p)))

    def test_staging_copies_and_rejects_changed_font_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg, wine = root / "app", root / "unix/wine/fonts"
            runtime = pkg / "Sources/S1Probe/Runtime"
            wine.mkdir(parents=True)
            pkg.mkdir()
            rows = []
            for name in stage.FONTS:
                src = wine / name
                src.write_bytes(b"\0\1\0\0" + name.encode())
                rows.append("\t".join(["resource", "Runtime/fonts/" + name, str(src.stat().st_size),
                                       stage.sha256(src), "unix", "wine/fonts/" + name, "fonts"]))
            manifest = pkg / "artifacts.tsv"
            manifest.write_text("\n".join(rows) + "\n")
            with patch.multiple(stage, PKG=pkg, RUNTIME=runtime, MANIFEST=manifest, ROOTS={"unix": root / "unix"}):
                stage.stage()
                for name in stage.FONTS:
                    self.assertEqual((runtime / "fonts" / name).read_bytes(), (wine / name).read_bytes())
                self.assertEqual((runtime / "artifacts.tsv").read_bytes(), manifest.read_bytes())
                (wine / stage.FONTS[0]).write_bytes(b"tampered")
                with self.assertRaisesRegex(SystemExit, "mismatch"):
                    stage.stage()

    def test_both_variants_and_notices_include_fonts(self):
        text = (REPO / "app/xtool.yml").read_text()
        self.assertIn("  - Sources/S1Probe/Runtime/fonts\n", text)
        self.assertIn("  - Runtime/fonts\n", stage.release_xtool_yml(text))
        selection = json.loads((REPO / "build/app-notices.json").read_text())
        wine = next(c for c in selection["components"] if c["name"] == "Wine")
        self.assertIn("fonts", wine["covers"])
        self.assertIn("wine-*", wine["include"])
        collection = (REPO / "build/notices-assemble.sh").read_text()
        for name in ("tahoma", "tahomabd"):
            self.assertIn(f'excerpt_ wine-fonts-{name}-attribution.txt "$WINE/fonts/{name}.sfd" 1 6', collection)


if __name__ == "__main__":
    unittest.main()
