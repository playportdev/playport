# SPDX-License-Identifier: GPL-3.0-or-later
"""madeira-unix 0205's owner of the phone's layer (playport_vk_surface_shown, PLA-364).

The patch's own code (driver_ios.c's added lines, from WINIOS_VK_SURFACES to the end of
playport_vk_surface_shown) is compiled on this host against stand-ins for the win32u calls it
makes (top-level ancestor, foreground window, is_window, the style's WS_VISIBLE, the tick count),
and driven through the case it was made for: the Rockstar launcher's window and its in-process
Social Club sign-in window presenting in turns."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0205-win32u-one-top-level-window-owns-the-phone-s-layer-f.patch"


def added_code():
    out, current = [], None
    for line in PATCH.read_text().splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif line.startswith("+") and not line.startswith("+++") and current == "build/win32u-unix/driver_ios.c":
            out.append(line[1:])
    text = "\n".join(out)
    start = text.index("#define WINIOS_VK_SURFACES")
    end = text.index("    return shown;\n}", start) + len("    return shown;\n}")
    return text[start:end]


PRELUDE = r'''
#include <pthread.h>
#include <stdio.h>
#include <string.h>
typedef void *HWND; typedef int BOOL; typedef unsigned long long ULONGLONG; typedef unsigned long UINT_PTR;
#define TRUE 1
#define FALSE 0
#define GA_ROOT 2
#define GWL_STYLE (-16)
#define WS_VISIBLE 0x10000000
#define dprintf(fd, ...) printf(__VA_ARGS__)
static HWND roots[16], foreground_window; static int alive[16], visible[16]; static unsigned long tick = 5000;
static int idx(HWND h) { return (int)(UINT_PTR)h; }
static HWND NtUserGetAncestor(HWND h, int type) { return roots[idx(h)]; }
static HWND NtUserGetForegroundWindow(void) { return foreground_window; }
static BOOL is_window(HWND h) { return alive[idx(h)]; }
static unsigned int get_window_long(HWND h, int off) { return visible[idx(h)] ? WS_VISIBLE : 0; }
static unsigned long NtGetTickCount(void) { return tick; }
'''

TEST = r'''
#define W(n) ((HWND)(UINT_PTR)(n))
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
int main(void)
{
    /* window 1: the launcher (top level); 2: the sign-in popup (top level); 3: its browser child */
    int s1, s1b, s3, unknown, i, changes = 0;
    for (i = 1; i < 4; i++) { alive[i] = visible[i] = 1; }
    roots[1] = W(1); roots[2] = W(2); roots[3] = W(2);

    winios_vk_surface_created(&s1, W(1));
    winios_vk_surface_created(&s1b, W(1));
    CHECK(playport_vk_surface_shown(&s1) && playport_vk_surface_shown(&s1b)); /* one window: all shown */
    CHECK(playport_vk_surface_shown(&unknown));

    foreground_window = W(1);
    winios_vk_surface_created(&s3, W(3));
    for (i = 0; i < 100; i++) {          /* the two windows present in turns: no flapping */
        CHECK(playport_vk_surface_shown(&s1));
        CHECK(!playport_vk_surface_shown(&s3));
    }
    tick += 2000;
    foreground_window = W(3);            /* the sign-in window comes to the front (its root is 2) */
    for (i = 0; i < 100; i++) {
        CHECK(playport_vk_surface_shown(&s3));
        CHECK(!playport_vk_surface_shown(&s1));
    }
    foreground_window = 0;               /* no foreground: the owner stays */
    CHECK(playport_vk_surface_shown(&s3) && !playport_vk_surface_shown(&s1));
    tick += 100;                         /* within a second of the last line: counted, not logged */
    visible[2] = 0;                      /* the sign-in window hides: the launcher presents and owns */
    CHECK(playport_vk_surface_shown(&s1) && playport_vk_surface_shown(&s1b));
    CHECK(!playport_vk_surface_shown(&s3));
    tick += 2000;
    alive[1] = 0; visible[2] = 1;        /* the launcher is destroyed: the visible sign-in window owns */
    CHECK(playport_vk_surface_shown(&s3) && !playport_vk_surface_shown(&s1));
    puts("vk shown: ok");
    return 0;
}
'''


@unittest.skipUnless(shutil.which("clang"), "needs clang")
class VkShown(unittest.TestCase):
    def test_owner_moves_only_on_foreground_or_loss(self):
        scratch = pathlib.Path(os.environ.get("PLAYPORT_BUILD", ROOT / ".work")) / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "t.c").write_text(PRELUDE + added_code() + TEST)
            subprocess.run(["clang", "-std=gnu11", "-w", "-pthread", "-o", str(tmp / "t"), str(tmp / "t.c")],
                           check=True)
            out = subprocess.run([str(tmp / "t")], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("vk shown: ok", out.stdout)
        lines = [l for l in out.stdout.splitlines() if l.startswith("[vk-shown]")]
        # first window, foreground -> sign-in, (hidden -> launcher: within a second, not logged),
        # launcher gone -> sign-in, which reports the one change not logged
        self.assertEqual(len(lines), 3, out.stdout)
        self.assertIn("window 0x2 (the foreground window", lines[1])
        self.assertIn("1 earlier changes not logged", lines[2])


if __name__ == "__main__":
    unittest.main()
