# SPDX-License-Identifier: GPL-3.0-or-later
"""The trusted roots (Runtime/certs/cacert.pem): one date and one sha256 wherever the
bundle is named, so a hand refresh (docs/BUILDING.md, "The trusted roots") cannot
move only some of them."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ca_stage", REPO / "build/stages/stage-artifacts.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class CABundle(unittest.TestCase):
    def test_pin_stage_script_and_source_catalog_agree(self):
        date = stage.pin("ca-bundle")
        self.assertRegex(date, r"^\d{4}-\d{2}-\d{2}$")
        script = (REPO / "build/stages/ca-bundle.sh").read_text()
        sha = re.search(r"^SHA256=([0-9a-f]{64})$", script, re.M).group(1)
        entry = next(f for f in json.loads((REPO / "build/source-bundle.json").read_text())["files"]
                     if f["name"] == "ca-bundle")
        self.assertEqual((entry["tag"], entry["sha256"]), (date, sha))
        self.assertEqual(entry["file"], f"cacert-{date}.pem")
        self.assertEqual(entry["url"], f"https://curl.se/ca/cacert-{date}.pem")

    def test_staged_packaged_verified_and_noticed(self):
        self.assertEqual(stage.ROOTS["ca-bundle"].name, f"ca-bundle-{stage.pin('ca-bundle')}")
        text = (REPO / "app/xtool.yml").read_text()
        self.assertIn("  - Sources/S1Probe/Runtime/certs\n", text)
        self.assertIn("  - Runtime/certs\n", stage.release_xtool_yml(text))
        self.assertIn('"certs"', (REPO / "build/verify-ipa.py").read_text())
        selection = json.loads((REPO / "build/app-notices.json").read_text())
        self.assertTrue(any("ca-bundle" in c["covers"] for c in selection["components"]))
        self.assertIn('"%s/certs/cacert.pem"', (REPO / "app/Sources/WineHost/wine_host.c").read_text())


if __name__ == "__main__":
    unittest.main()
