# SPDX-License-Identifier: GPL-3.0-or-later
"""pp pad wait-still and wait-text: the thumbnail difference, the OCR match and
the wait loops, on synthetic screenshots (no phone)."""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pad  # noqa: E402
import phonelib  # noqa: E402

try:
    from PIL import Image, ImageDraw
except ImportError:   # CI's runner has no Pillow; wait-still needs it on the workstation
    Image = None


def frame(path, x, noise=0):
    """A 640x360 dark screen with a light box at x (a menu cursor that moves)."""
    im = Image.new("RGB", (640, 360), (20 + noise, 20, 30))
    ImageDraw.Draw(im).rectangle([x, 150, x + 120, 210], fill=(230, 230, 230))
    im.save(path)
    return path


@unittest.skipIf(Image is None, "no Pillow")
class WaitStill(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        self.events = []

    def tearDown(self):
        shutil.rmtree(self.d)

    def ev(self, kind, **kw):
        self.events.append((kind, kw))

    def test_difference(self):
        a = frame(os.path.join(self.d, "a.png"), 100)
        self.assertEqual(pad.difference(a, frame(os.path.join(self.d, "b.png"), 100)), 0)
        self.assertLess(pad.difference(a, frame(os.path.join(self.d, "c.png"), 100, noise=1)), 1.5)
        self.assertGreater(pad.difference(a, frame(os.path.join(self.d, "d.png"), 400)), 5)

    def shooter(self, xs):
        """A stand-in for Phone.screenshot that draws the cursor at each x in turn."""
        it = iter(xs)

        def shoot(path):
            return frame(path, next(it))
        return shoot

    def test_settles_after_the_cursor_stops(self):
        path = os.path.join(self.d, "still.png")
        self.assertTrue(pad.wait_still(None, self.ev, path, timeout=60, shoot=self.shooter([100, 250, 400, 400])))
        diffs = [kw["difference"] for k, kw in self.events if k == "still-check"]
        self.assertEqual(len(diffs), 3)
        self.assertEqual(diffs[-1], 0)
        self.assertTrue(os.path.exists(path))

    def test_gives_up_on_a_screen_that_keeps_changing(self):
        path = os.path.join(self.d, "still.png")
        self.assertFalse(pad.wait_still(None, self.ev, path, timeout=0, shoot=self.shooter([100, 400])))

    def test_no_screenshot_is_an_error(self):
        with self.assertRaises(phonelib.PhoneError):
            pad.wait_still(None, self.ev, os.path.join(self.d, "x.png"), shoot=lambda p: None)


class FoundTexts(unittest.TestCase):
    def test_case_and_spacing_aside(self):
        read = "CONTINUE\nNew  game\nLOAD\nGAME\nSettings"
        self.assertEqual(pad.found_texts(read, ["New Game", "Load Game", "Settings", "Quit"]),
                         ["New Game", "Load Game", "Settings"])
        self.assertEqual(pad.found_texts("", ["New Game"]), [])


class Phone:
    """Records what wait-text pushes to the pad."""
    def __init__(self):
        self.pushed = []

    def put(self, remote, data):
        self.pushed.append((remote, data.decode()))


class WaitText(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        self.path = os.path.join(self.d, "text.png")
        self.events = []
        self.phone = Phone()

    def tearDown(self):
        shutil.rmtree(self.d)

    def ev(self, kind, **kw):
        self.events.append((kind, kw))

    def run_screens(self, screens, **kw):
        """wait_text over SCREENS, the OCR text of each screenshot in turn."""
        it = iter(screens)
        reads = {}

        def shoot(path):
            reads[path] = next(it)
            return path
        return pad.wait_text(self.phone, self.ev, self.path, ["New Game", "Load Game", "Settings"],
                             shoot=shoot, read=lambda p: reads[p], sleep=lambda s: None, **kw)

    def test_presses_through_the_intro_until_the_menu(self):
        menu = "Continue New Game Load Game Settings"
        self.assertTrue(self.run_screens(["", "WARHORSE", "", menu], press="150 B\n300 -\n", timeout=60))
        self.assertEqual(self.phone.pushed, [(pad.REMOTE, "150 B\n300 -\n")] * 3)
        self.assertEqual([kw["found"] for k, kw in self.events if k == "text-check"][-1],
                         ["New Game", "Load Game", "Settings"])

    def test_stops_pressing_once_any_text_is_seen(self):
        screens = ["", "New Game", "New Game Load", "New Game Load Game"]
        self.assertTrue(self.run_screens(screens, need=2, press="150 B\n", timeout=60))
        self.assertEqual(len(self.phone.pushed), 1)

    def test_need_counts_the_texts_read(self):
        self.assertTrue(self.run_screens(["New Game Settings"], need=2))
        self.assertFalse(self.run_screens(["New Game"], need=2, timeout=0))
        self.assertEqual(self.phone.pushed, [])

    def test_gives_up_without_pressing_on(self):
        self.assertFalse(self.run_screens([""], press="150 B\n", timeout=0))
        self.assertEqual(self.phone.pushed, [])

    def test_no_screenshot_is_an_error(self):
        with self.assertRaises(phonelib.PhoneError):
            pad.wait_text(self.phone, self.ev, self.path, ["New Game"], shoot=lambda p: None)


@unittest.skipIf(Image is None or not shutil.which("tesseract"), "no Pillow or tesseract")
class Ocr(unittest.TestCase):
    def test_reads_light_menu_text_on_a_dark_screen(self):
        from PIL import ImageFont
        d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        try:
            path = os.path.join(d, "menu.png")
            im = Image.new("RGB", (1600, 740), (24, 20, 16))
            draw = ImageDraw.Draw(im)
            font = ImageFont.load_default(size=44)
            for i, label in enumerate(["Continue", "New Game", "Load Game", "Settings"]):
                draw.text((160, 200 + 80 * i), label, fill=(225, 215, 190), font=font)
            im.save(path)
            self.assertEqual(pad.found_texts(pad.ocr(path), ["New Game", "Load Game", "Settings"]),
                             ["New Game", "Load Game", "Settings"])
            self.assertEqual(os.listdir(d), ["menu.png"])
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
