# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0177's pp_game_sc_refuse.h (PLA-413, decision 0138, dev): with
PLAYPORT_REFUSE_GAME_SC_RESTART=1, RDR2.exe's first SocialClubHelper.exe start goes ahead and every later one is
refused at process creation; the launcher's helper and Chromium's --type= children are left alone."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0177-ntdll-refuse-RDR2-s-later-Social-Club-helper-starts-.patch"
HEADER = "build/ntdll-unix/pp_game_sc_refuse.h"

TEST_C = r'''
#include "pp_game_sc_refuse.h"
#include <assert.h>
#include <string.h>

static size_t w(pp_wchar *out, const char *s) {
    size_t n = strlen(s);
    for (size_t i = 0; i < n; i++) out[i] = (unsigned char)s[i];
    return n;
}

static unsigned start(struct ppgsc_state *st, int on, void *id, const char *creator, const char *image) {
    pp_wchar c[256], im[256];
    size_t cl = w(c, creator), il = w(im, image);
    return ppgsc_refuse(st, on, id, c, cl, im, il);
}

#define GAME "C:\\Games\\Red Dead Redemption 2\\RDR2.exe"
#define HELPER "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe"
#define LAUNCHER "C:\\Program Files\\Rockstar Games\\Launcher\\Launcher.exe"

int main(void) {
    struct ppgsc_state st = {0};
    int a, b;
    /* off: nothing refused */
    assert(start(&st, 0, &a, GAME, HELPER) == 0 && start(&st, 0, &a, GAME, HELPER) == 0);
    /* on: the game's first start goes ahead, the later ones are refused and numbered */
    assert(start(&st, 1, &a, GAME, HELPER) == 0);
    assert(start(&st, 1, &a, GAME, HELPER) == 2);
    assert(start(&st, 1, &a, "c:/games/rdr2.EXE", "socialclubhelper.exe") == 3);
    /* the launcher's helper, PlayRDR2.exe, a child of the helper, other images: never counted */
    assert(start(&st, 1, &b, LAUNCHER, HELPER) == 0);
    assert(start(&st, 1, &b, "C:\\Games\\Red Dead Redemption 2\\PlayRDR2.exe", HELPER) == 0);
    assert(start(&st, 1, &b, HELPER, HELPER) == 0);
    assert(start(&st, 1, &a, GAME, "C:\\Windows\\system32\\werfault.exe") == 0);
    assert(start(&st, 1, &a, GAME, "C:\\x\\NotSocialClubHelper.exe") == 0);
    assert(start(&st, 1, &a, GAME, "\"" HELPER "\"") == 4);
    /* a new game process counts from its first start again */
    assert(start(&st, 1, &b, GAME, HELPER) == 0);
    assert(start(&st, 1, &b, GAME, HELPER) == 2);
    assert(ppgsc_refuse(&st, 1, &b, 0, 0, 0, 0) == 0);
    return 0;
}
'''


class GameScRefuseTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str((d / HEADER).parent),
                            "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_nt_create_user_process_uses_it(self):
        text = PATCH.read_text()
        self.assertIn('+        const char *on = getenv( "PLAYPORT_REFUSE_GAME_SC_RESTART" );', text)
        self.assertIn("+            return STATUS_ACCESS_DENIED;", text)


if __name__ == "__main__":
    unittest.main()
