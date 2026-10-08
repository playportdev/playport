# SPDX-License-Identifier: GPL-3.0-or-later
"""The public compatibility list: site/compatibility/games.json and the links to it.

games.json is a scrubbed summary of Linear project Compatibility. Check its shape,
its order, and that no private detail (player names, IPA hashes, run paths, tracker
IDs) slipped in from the issues it summarises.
"""

from pathlib import Path
import json
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
SITE = REPO / "site" / "compatibility"
STATUSES = {"works", "issues", "broken"}
STORES = {"steam", "gog", "epic", "other"}
REQUIRED = {"name", "store", "status", "notes", "tested", "device", "build"}
OPTIONAL = {"id", "reported"}
PRIVATE = [
    (re.compile(r"\bu/\w"), "a Reddit username"),
    (re.compile(r"\bPLA-\d+"), "a Linear issue ID"),
    (re.compile(r"linear\.app"), "a Linear link"),
    (re.compile(r"\.work/"), "a build-area path"),
    (re.compile(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{8,}\b"), "a hash"),
    (re.compile(r"iPhone\d+,\d+"), "a device model identifier"),
    (re.compile(r"0x[0-9a-fA-F]+"), "an exit code (say what happens instead)"),
]
REPORT = "issues/new?template=game-report.yml"


def fold(s):
    return s.casefold()


class GamesJson(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((SITE / "games.json").read_text(encoding="utf-8"))
        self.games = self.data["games"]

    def test_entries(self):
        self.assertRegex(self.data["updated"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertTrue(self.games)
        for g in self.games:
            with self.subTest(game=g.get("name")):
                self.assertLessEqual(REQUIRED, set(g))
                self.assertLessEqual(set(g), REQUIRED | OPTIONAL)
                self.assertIn(g["status"], STATUSES)
                self.assertIn(g["store"], STORES)
                self.assertRegex(g["tested"], r"^\d{4}-\d{2}-\d{2}$")
                self.assertLessEqual(g["tested"], self.data["updated"])
                if "id" in g:
                    self.assertRegex(g["id"], r"^\d+$")
                if g["store"] == "steam":
                    self.assertIn("id", g, "a Steam entry needs its app ID")
                if "reported" in g:
                    self.assertIs(g["reported"], True)
                for key in ("name", "notes", "device", "build"):
                    self.assertTrue(g[key].strip())

    def test_sorted_and_unique(self):
        names = [fold(g["name"]) for g in self.games]
        self.assertEqual(names, sorted(names), "keep games.json sorted by name")
        self.assertEqual(len(names), len(set(names)))
        ids = [(g["store"], g["id"]) for g in self.games if "id" in g]
        self.assertEqual(len(ids), len(set(ids)))

    def test_no_private_detail(self):
        for g in self.games:
            text = " ".join(str(v) for k, v in g.items() if k != "id")
            for pattern, what in PRIVATE:
                with self.subTest(game=g["name"], what=what):
                    self.assertIsNone(pattern.search(text), f"{g['name']}: {what}")


class Links(unittest.TestCase):
    def test_page_and_template(self):
        page = (SITE / "index.html").read_text(encoding="utf-8")
        self.assertIn('fetch("games.json"', page)
        self.assertIn(REPORT, page)
        self.assertTrue((REPO / ".github" / "ISSUE_TEMPLATE" / "game-report.yml").is_file())

    def test_linked_from_landing_page_and_readme(self):
        self.assertIn('href="compatibility/"', (REPO / "site" / "index.html").read_text(encoding="utf-8"))
        readme = (REPO / "README.md").read_text(encoding="utf-8")
        self.assertIn("https://playport.dev/compatibility/", readme)
        self.assertIn(REPORT, readme)


if __name__ == "__main__":
    unittest.main()
