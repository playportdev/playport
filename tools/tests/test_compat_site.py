# SPDX-License-Identifier: GPL-3.0-or-later
"""The public compatibility list: site/compatibility/games.json and the links to it.

games.json holds each title's status from Linear project Compatibility and nothing
else: details stay in Linear.
"""

from pathlib import Path
import json
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
SITE = REPO / "site" / "compatibility"
STATUSES = {"works", "issues", "broken"}
STORES = {"steam", "gog", "epic", "other"}
REPORT = "issues/new?template=problem.yml"


class GamesJson(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((SITE / "games.json").read_text(encoding="utf-8"))
        self.games = self.data["games"]

    def test_entries(self):
        self.assertRegex(self.data["updated"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertTrue(self.games)
        for g in self.games:
            with self.subTest(game=g.get("name")):
                self.assertLessEqual({"name", "store", "status"}, set(g))
                self.assertLessEqual(set(g), {"name", "store", "id", "status"})
                self.assertTrue(g["name"].strip())
                self.assertIn(g["status"], STATUSES)
                self.assertIn(g["store"], STORES)
                if "id" in g:
                    self.assertRegex(g["id"], r"^\d+$")
                if g["store"] == "steam":
                    self.assertIn("id", g, "a Steam entry needs its app ID")

    def test_sorted_and_unique(self):
        names = [g["name"].casefold() for g in self.games]
        self.assertEqual(names, sorted(names), "keep games.json sorted by name")
        self.assertEqual(len(names), len(set(names)))
        ids = [(g["store"], g["id"]) for g in self.games if "id" in g]
        self.assertEqual(len(ids), len(set(ids)))


class Links(unittest.TestCase):
    def test_page_and_template(self):
        page = (SITE / "index.html").read_text(encoding="utf-8")
        self.assertIn('fetch("games.json"', page)
        self.assertIn(REPORT, page)
        template = (REPO / ".github" / "ISSUE_TEMPLATE" / "problem.yml").read_text(encoding="utf-8")
        for status in ("Works", "Playable with issues", "Broken"):
            self.assertRegex(template, rf"(?m)^\s+- {re.escape(status)}$")

    def test_linked_from_landing_page_and_readme(self):
        self.assertIn('href="compatibility/"', (REPO / "site" / "index.html").read_text(encoding="utf-8"))
        readme = (REPO / "README.md").read_text(encoding="utf-8")
        self.assertIn("https://playport.dev/compatibility/", readme)
        self.assertIn(REPORT, readme)


if __name__ == "__main__":
    unittest.main()
