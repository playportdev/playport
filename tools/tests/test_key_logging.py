# SPDX-License-Identifier: GPL-3.0-or-later
"""No log line on the host's key path names a key (PLA-267, PLA-606).

A letter's or digit's virtual key is its ASCII code, so a log of the keys posted is the
text typed, a password included, and stderr is the app's log in a release build too.
Winios.m (patches/madeira-winios over the Madeira pin) queues the keys and the text bar's
characters; win32u's driver_ios.c (patches/madeira-unix) sends them."""

import os
import re
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WINIOS = os.path.join(ROOT, "upstream", "madeira", "app", "Madeira", "Winios", "Winios.m")
LOG_CALL = re.compile(r"\b(?:f?printf|dprintf|NSLog|TRACE|WARN|ERR)\s*\(")


def series(target):
    d = os.path.join(ROOT, "patches", target)
    with open(os.path.join(d, "series")) as f:
        return [os.path.join(d, x.strip()) for x in f if x.strip() and not x.startswith("#")]


def function(source, signature):
    """The lines of the C function whose definition starts with `signature`, to its closing brace."""
    lines = source.splitlines()
    start = next(i for i, x in enumerate(lines) if x.startswith(signature))
    end = next(i for i in range(start, len(lines)) if lines[i] == "}")
    return lines[start:end + 1]


class KeyLogging(unittest.TestCase):
    def test_winios_queues_keys_and_characters_without_logging_them(self):
        if not os.path.exists(WINIOS):
            self.skipTest("upstream/madeira is not checked out")
        with tempfile.TemporaryDirectory() as d:
            target = os.path.join(d, "app", "Madeira", "Winios")
            os.makedirs(target)
            with open(WINIOS, "rb") as src, open(os.path.join(target, "Winios.m"), "wb") as dst:
                dst.write(src.read())
            # A repository of its own: under one (pp test's TMPDIR is in the build area), git apply
            # would skip every path outside the directory it runs in, applying nothing.
            subprocess.run(["git", "init", "-q"], cwd=d, check=True)
            for patch in series("madeira-winios"):
                subprocess.run(["git", "apply", "--include=app/Madeira/Winios/Winios.m", patch], cwd=d, check=True,
                               capture_output=True)
            with open(os.path.join(target, "Winios.m"), errors="replace") as f:
                source = f.read()
        for signature in ("void winios_post_key(int vk, int down)", "void winios_post_key_extended(int vk, int down)",
                          "void winios_post_char(unsigned int unit)"):
            body = function(source, signature)
            self.assertFalse([x for x in body if LOG_CALL.search(x)], signature)
        # The drain logs the other events it hands on, never a key or a character.
        lines = source.splitlines()
        drains = [i for i, x in enumerate(lines) if "[winios] drain type=" in x]
        self.assertTrue(drains)
        for i in drains:
            self.assertIn("e.type != WINIOS_EV_KEY && e.type != WINIOS_EV_CHAR", lines[i - 1])

    def test_win32u_counts_posted_keys_without_naming_them(self):
        # Every line the series leaves in driver_ios.c's key and character posts: none logs the key,
        # its scan code or the character (the last word on a format is the patch that removes it).
        last = {}
        for patch in series("madeira-unix"):
            with open(patch, errors="replace") as f:
                text = f.read()
            for sign, line in re.findall(r"^([+-])(.*drv_post_key #%u.*)$", text, re.M):
                last[line.strip()] = sign
        left = [line for line, sign in last.items() if sign == "+"]
        self.assertEqual(left, ['dprintf(2, "[winios] ml647 drv_post_key #%u -> status=0x%x (failures=%u)\\n",'])
        char = next(p for p in series("madeira-unix") if "post-a-Unicode-character" in p)
        with open(char, errors="replace") as f:
            added = [x for x in f.read().splitlines() if x.startswith("+")]
        self.assertFalse([x for x in added if LOG_CALL.search(x)])


if __name__ == "__main__":
    unittest.main()
