# SPDX-License-Identifier: GPL-3.0-or-later
"""The app icon (app/Icon): the dev xtool.yml names the icon with the DEV tab, the
release package's the one without (build/stages/stage-artifacts.py release), and
both PNGs are what iOS takes as a single-size icon: 1024 px square, no alpha."""

import importlib.util
import os
import struct
import unittest

import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
spec = importlib.util.spec_from_file_location("stage_artifacts", os.path.join(REPO, "build/stages/stage-artifacts.py"))
stage_artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage_artifacts)


class AppIcon(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(REPO, "app/xtool.yml")) as f:
            self.dev = f.read()

    def test_each_variant_names_its_icon(self):
        self.assertEqual(yaml.safe_load(self.dev)["iconPath"], "Icon/AppIcon-dev.png")
        rel = yaml.safe_load(stage_artifacts.release_xtool_yml(self.dev))
        self.assertEqual(rel["iconPath"], "Icon/AppIcon.png")
        self.assertIn("Icon", stage_artifacts.RELEASE_LINKS)

    def test_a_missing_icon_line_is_refused(self):
        with self.assertRaises(SystemExit):
            stage_artifacts.release_xtool_yml(self.dev.replace("iconPath: Icon/AppIcon-dev.png\n", ""))

    def test_pngs_are_1024_square_without_alpha(self):
        for name in ("AppIcon.png", "AppIcon-dev.png"):
            with open(os.path.join(REPO, "app/Icon", name), "rb") as f:
                head = f.read(26)
            self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n", name)
            w, h, depth, color = struct.unpack(">IIBB", head[16:26])
            self.assertEqual((w, h, depth, color), (1024, 1024, 8, 2), f"{name}: 1024x1024 8-bit RGB")


if __name__ == "__main__":
    unittest.main()
