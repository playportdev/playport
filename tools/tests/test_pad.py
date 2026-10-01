# SPDX-License-Identifier: GPL-3.0-or-later
"""pp pad wait-still: the thumbnail difference and the wait loop, on synthetic
screenshots (no phone)."""

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


if __name__ == "__main__":
    unittest.main()
