# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0213's allow in pp_game_sc_refuse.h (PLA-413, decision 0155): with
PLAYPORT_REFUSE_GAME_SC_RESTART=1 RDR2.exe's later SocialClubHelper.exe starts are refused (0177), but after the
app allows them (ios_game_sc_allow_restarts(1), after the game signs in again following their end) one goes
ahead, numbered as before, and uses the allow up (0239, decision 0155 amended after run l13): the next one is
refused until the app allows again; refusing again (0) before any start also refuses the next one."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCHES = [ROOT / "patches/madeira-unix/0177-ntdll-refuse-RDR2-s-later-Social-Club-helper-starts-.patch",
           ROOT / "patches/madeira-unix/0212-ntdll-PLAYPORT_SC_BLOCK_CRASHPAD-1-refuses-crash-rep.patch",
           ROOT / "patches/madeira-unix/0213-ntdll-the-app-allows-RDR2-s-Social-Club-helper-resta.patch",
           ROOT / "patches/madeira-unix/0239-ntdll-an-allowed-Social-Club-restart-is-used-by-one-.patch"]
HEADER = "build/ntdll-unix/pp_game_sc_refuse.h"

# NtCreateUserProcess's decision as 0213 and 0239 make it: 0 refused, 1 started, 2 started as an allowed restart.
TEST_C = r'''
#include "pp_game_sc_refuse.h"
#include <assert.h>
#include <string.h>

static size_t w(pp_wchar *out, const char *s) {
    size_t n = strlen(s);
    for (size_t i = 0; i < n; i++) out[i] = (unsigned char)s[i];
    return n;
}

static struct ppgsc_state game_sc;
static unsigned last;

static int start(void *id, const char *creator, const char *image) {
    pp_wchar c[256], im[256];
    size_t cl = w(c, creator), il = w(im, image);
    unsigned n = ppgsc_refuse(&game_sc, 1, id, c, cl, im, il);
    last = n;
    if (n && ppgsc_take_allow(&game_sc)) return 2;
    return n ? 0 : 1;
}

#define GAME "C:\\Games\\Red Dead Redemption 2\\RDR2.exe"
#define HELPER "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe"

int main(void) {
    int a;
    /* refused by default after the first, as 0177 does */
    assert(!ppgsc_allowed(&game_sc));
    assert(start(&a, GAME, HELPER) == 1);
    assert(start(&a, GAME, HELPER) == 0 && last == 2);
    assert(start(&a, GAME, HELPER) == 0 && last == 3);
    /* allowed: the next start goes ahead, still numbered, and uses the allow up */
    ppgsc_set_allow(&game_sc, 1);
    assert(ppgsc_allowed(&game_sc) == 1);
    /* the allow changes nothing for a start the refusal never counts, and is not used by it */
    assert(start(&a, GAME, "C:\\Windows\\system32\\werfault.exe") == 1);
    assert(ppgsc_allowed(&game_sc) == 1);
    assert(start(&a, GAME, HELPER) == 2 && last == 4);
    assert(!ppgsc_allowed(&game_sc));
    /* l13: that helper dies and the game starts the next at once: refused */
    assert(start(&a, GAME, HELPER) == 0 && last == 5);
    assert(start(&a, GAME, HELPER) == 0 && last == 6);
    /* the app's refuse-again after a used allow changes nothing */
    ppgsc_set_allow(&game_sc, 0);
    assert(start(&a, GAME, HELPER) == 0 && last == 7);
    /* any nonzero allows; a second allow is one start again */
    ppgsc_set_allow(&game_sc, 7);
    assert(ppgsc_allowed(&game_sc) == 1);
    assert(start(&a, GAME, HELPER) == 2 && last == 8);
    assert(start(&a, GAME, HELPER) == 0 && last == 9);
    /* an allow refused again before any start: the next start is refused */
    ppgsc_set_allow(&game_sc, 1);
    ppgsc_set_allow(&game_sc, 0);
    assert(start(&a, GAME, HELPER) == 0 && last == 10);
    return 0;
}
'''


class GameScAllowTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            for patch in PATCHES:
                subprocess.run(["git", "apply", f"--include={HEADER}", str(patch)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str((d / HEADER).parent),
                            "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_nt_create_user_process_uses_it(self):
        text = PATCHES[2].read_text()
        self.assertIn("+void ios_game_sc_allow_restarts( int on )", text)
        self.assertIn('+        if (n && ppgsc_allowed( &game_sc ))', text)
        self.assertIn('+            dprintf( 2, "[game-sc] restart allowed start %u\\n", n );', text)
        used = PATCHES[3].read_text()
        self.assertIn("+        if (n && ppgsc_take_allow( &game_sc ))", used)
        self.assertIn("-        if (n && ppgsc_allowed( &game_sc ))", used)
        host = (ROOT / "app/Sources/WineHost/wine_host.c").read_text()
        self.assertIn("ios_game_sc_allow_restarts(on ? 1 : 0);", host)


if __name__ == "__main__":
    unittest.main()
