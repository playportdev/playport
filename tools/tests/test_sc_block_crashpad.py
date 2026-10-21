# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0212's ppgsc_is_crashpad (pp_game_sc_refuse.h, dev): with
PLAYPORT_SC_BLOCK_CRASHPAD=1 a start of Rockstar's crash reporter RockstarErrorHandler.exe, or of a
Chromium crashpad handler (--type=crashpad-handler in its command line), is refused at process
creation; Social Club's helper and its other Chromium children are not."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCHES = [ROOT / "patches/madeira-unix/0177-ntdll-refuse-RDR2-s-later-Social-Club-helper-starts-.patch",
           ROOT / "patches/madeira-unix/0212-ntdll-PLAYPORT_SC_BLOCK_CRASHPAD-1-refuses-crash-rep.patch"]
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

static int crashpad(const char *image, const char *cmdline) {
    pp_wchar im[512], cl[512];
    size_t il = image ? w(im, image) : 0, cll = cmdline ? w(cl, cmdline) : 0;
    return ppgsc_is_crashpad(image ? im : 0, il, cmdline ? cl : 0, cll);
}

#define HANDLER "C:\\Program Files\\Rockstar Games\\Launcher\\ThirdParty\\Crashpad\\RockstarErrorHandler.exe"
#define HELPER "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe"

int main(void) {
    assert(crashpad(HANDLER, "\"" HANDLER "\" --database=x"));
    assert(crashpad("c:/x/rockstarerrorhandler.EXE", 0));
    assert(crashpad("\"" HANDLER "\"", 0));
    assert(crashpad(HELPER, "\"" HELPER "\" --type=crashpad-handler --monitor-self"));
    assert(crashpad(HELPER, "x --TYPE=Crashpad-Handler"));
    assert(!crashpad(HELPER, "\"" HELPER "\" --type=renderer"));
    assert(!crashpad(HELPER, "\"" HELPER "\""));
    assert(!crashpad("C:\\x\\NotRockstarErrorHandler.exe", "y"));
    assert(!crashpad(HELPER, "--type=crashpad-handle"));
    assert(!crashpad(0, 0));
    return 0;
}
'''


class ScBlockCrashpadTests(unittest.TestCase):
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
        text = PATCHES[1].read_text()
        self.assertIn('+        const char *on = getenv( "PLAYPORT_SC_BLOCK_CRASHPAD" );', text)
        self.assertIn("+            return STATUS_ACCESS_DENIED;", text)


if __name__ == "__main__":
    unittest.main()
