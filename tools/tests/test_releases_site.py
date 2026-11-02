# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/releases.py: site/releases/*.md and the generated releases page."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
import releases  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


class Committed(unittest.TestCase):
    def test_page_is_current(self):
        self.assertEqual(releases.main(["--check"]), 0,
                         "site/releases/index.html is stale: run python3 tools/releases.py")

    def test_every_release_newest_first(self):
        notes = releases.read_notes()
        versions = [r["version"] for r in notes]
        self.assertEqual(sorted(versions, key=releases.version_key, reverse=True), versions)
        self.assertEqual(set(versions), {p.stem for p in releases.NOTES.glob("*.md")})
        page = (releases.NOTES / "index.html").read_text(encoding="utf-8")
        positions = [page.index(f'<section class="release" id="v{v}">') for v in versions]
        self.assertEqual(positions, sorted(positions))
        for attr in ("src", "href"):
            self.assertNotIn(f'{attr}="{releases.SITE_URL}', page)

    def test_linked_from_site(self):
        self.assertIn('href="releases/"', (REPO / "site/index.html").read_text(encoding="utf-8"))
        self.assertIn('href="../releases/"', (REPO / "site/compatibility/index.html").read_text(encoding="utf-8"))

    def test_no_old_notes_folder(self):
        self.assertFalse((REPO / "docs/releases").exists(), "release notes live in site/releases/")


class Notes(unittest.TestCase):
    def read(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in files.items():
                Path(tmp, name).write_text(text, encoding="utf-8")
            return releases.read_notes(Path(tmp))

    def test_header_lines(self):
        notes = self.read({"0.10.0.md": "# Playport 0.10.0: ten\n<!-- date: 2026-12-01 -->\n\nBody\n",
                           "0.9.1.md": "# Playport 0.9.1\n<!-- date: 2026-11-01 -->\nBody\n"})
        self.assertEqual([(r["version"], r["tagline"], r["date"]) for r in notes],
                         [("0.10.0", "ten", "2026-12-01"), ("0.9.1", None, "2026-11-01")])

    def test_bad_header(self):
        for text in ("# Playport 0.9.0: wrong file\n<!-- date: 2026-11-01 -->\n",
                     "# Playport 0.9.1\n\nNo date\n",
                     "## Playport 0.9.1\n<!-- date: 2026-11-01 -->\n"):
            with self.subTest(text=text), self.assertRaises(releases.Bad):
                self.read({"0.9.1.md": text})


class Markdown(unittest.TestCase):
    def test_inline(self):
        self.assertEqual(releases.inline("**A** *b* `x<y>` & [GitHub](https://github.com/p)"),
                         '<strong>A</strong> <em>b</em> <code>x&lt;y&gt;</code> &amp; '
                         '<a href="https://github.com/p">GitHub</a>')
        self.assertEqual(releases.inline("snake_case_name and **two\nlines**"),
                         "snake_case_name and <strong>two\nlines</strong>")

    def test_site_links_become_relative(self):
        html = releases.markdown("![WoW](https://playport.dev/screenshots/wow.webp) "
                                 "[list](https://playport.dev/compatibility/)")
        self.assertIn('<img src="../screenshots/wow.webp" alt="WoW" loading="lazy">', html)
        self.assertIn('<a href="../compatibility/">list</a>', html)

    def test_blocks(self):
        html = releases.markdown("## Head\n\nText\nmore\n\n- one\n  cont\n  - nested\n- two\n\n"
                                 "1. a\n2. b\n\n| A | B |\n| --- | --- |\n| x | y |\n\n<!-- note -->\n",
                                 shift=1)
        self.assertEqual(html, "<h3>Head</h3>\n<p>Text\nmore</p>\n"
                               "<ul>\n<li>one\ncont\n<ul>\n<li>nested</li>\n</ul></li>\n<li>two</li>\n</ul>\n"
                               "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n"
                               '<div class="table"><table>\n<thead>\n<tr><th>A</th><th>B</th></tr>\n</thead>\n'
                               "<tbody>\n<tr><td>x</td><td>y</td></tr>\n</tbody>\n</table></div>")

    def test_raw_html_is_escaped(self):
        self.assertEqual(releases.markdown("<script>x</script>"), "<p>&lt;script&gt;x&lt;/script&gt;</p>")


if __name__ == "__main__":
    unittest.main()
