# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the available-memory rule shipped in madeira-unix 0234 (decision 0168, PLA-476):
SocialClubHelper.exe sees at most avail-phys-cef-mb, every other process the phone's figure; the log's
per-process limit (0237); and the wine-unix caller."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UNIX = ROOT / "patches/madeira-unix"
PATCH = UNIX / "0234-ntdll-tell-Social-Club-s-helper-little-available-mem.patch"
REFUSE = next(UNIX.glob("0177-*.patch"))
REFUSE_LATER = [next(UNIX.glob("0212-*.patch")), next(UNIX.glob("0213-*.patch"))]
LOG_LIMIT = UNIX / "0237-ntdll-log-the-available-memory-answers-per-Social-Cl.patch"
CALLER = ROOT / "patches/wine-unix/0203-ntdll-report-available-memory-through-ios_avail_phys.patch"


def added(patch, name):
    section = patch.read_text().split(f"diff --git a/build/ntdll-unix/{name}", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include "pp_avail_phys.h"

static size_t wide(pp_wchar *out, const char *s) {
    size_t i; for (i = 0; s[i]; i++) out[i] = (unsigned char)s[i]; out[i] = 0; return i;
}

int main(void) {
    pp_wchar path[256];
    unsigned long long gb3 = 3ull << 30, cap = ppap_cap(300);
    size_t n;

    /* The key: MB from 1 to 65536; 0, negative or past it is off. */
    assert(cap == 300ull << 20);
    assert(!ppap_cap(0) && !ppap_cap(-5) && !ppap_cap(65537) && ppap_cap(65536) == 65536ull << 20);

    /* Social Club's helper, any case, any folder, a quoted path's closing quote: capped. */
    n = wide(path, "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe");
    assert(ppap_available(gb3, cap, path, n) == cap);
    n = wide(path, "c:/x/SOCIALCLUBHELPER.EXE\"");
    assert(ppap_available(gb3, cap, path, n) == cap);
    /* Less than the cap is passed on as it is. */
    assert(ppap_available(100ull << 20, cap, path, n) == 100ull << 20);
    /* Off, or another process (the game, the launcher, a look-alike): the phone's figure. */
    assert(ppap_available(gb3, 0, path, n) == gb3);
    n = wide(path, "C:\\Games\\Red Dead Redemption 2\\RDR2.exe");
    assert(ppap_available(gb3, cap, path, n) == gb3);
    n = wide(path, "C:\\Program Files\\Rockstar Games\\Launcher\\Launcher.exe");
    assert(ppap_available(gb3, cap, path, n) == gb3);
    n = wide(path, "C:\\x\\SocialClubHelper.exe.bak");
    assert(ppap_available(gb3, cap, path, n) == gb3);
    n = wide(path, "C:\\x\\steamwebhelper.exe");
    assert(ppap_available(gb3, cap, path, n) == gb3);
    assert(ppap_available(gb3, cap, NULL, 0) == gb3);

    /* The log limit (0237): four answers for each of the first eight processes. */
    {
        static char peb[10];
        void *pebs[PPAP_LOG_PEBS] = {0};
        unsigned counts[PPAP_LOG_PEBS] = {0}, i;
        int p;
        assert(PPAP_LOG_PEBS == 8 && PPAP_LOG_LINES == 4);
        for (i = 0; i < 4; i++) assert(ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[0]));   /* A */
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[0]));
        for (i = 0; i < 4; i++) assert(ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[1]));   /* B, after A's */
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[1]));
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[0]));
        for (p = 2; p < PPAP_LOG_PEBS; p++) assert(ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[p]));
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[PPAP_LOG_PEBS]));               /* a ninth: none */
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[PPAP_LOG_PEBS]));
        assert(ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, &peb[7]));                             /* the eighth: its 2nd */
        assert(!ppap_log_slot(pebs, counts, PPAP_LOG_PEBS, NULL));
        for (p = 0; p < PPAP_LOG_PEBS; p++) assert(pebs[p] == &peb[p]);
    }
    return 0;
}
'''


class AvailPhysTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            unix = d / "build/ntdll-unix"
            unix.mkdir(parents=True)
            (unix / "pp_game_sc_refuse.h").write_text(added(REFUSE, "pp_game_sc_refuse.h"))
            # The header as the series leaves it; d is inside this repository's .work.
            env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(d.parent))
            for later in REFUSE_LATER:
                subprocess.run(["git", "apply", "--include=build/ntdll-unix/pp_game_sc_refuse.h", str(later)],
                               cwd=d, env=env, check=True)
            (unix / "pp_avail_phys.h").write_text(added(PATCH, "pp_avail_phys.h"))
            subprocess.run(["git", "apply", "--include=build/ntdll-unix/pp_avail_phys.h", str(LOG_LIMIT)],
                           cwd=d, env=env, check=True)
            (unix / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(unix / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_wine_reports_available_pages_through_it(self):
        text = CALLER.read_text()
        self.assertIn("+        info->AvailablePages  = ios_avail_phys( freeram ) / page_size;", text)
        self.assertIn("-    info->AvailablePages      = freeram / page_size;", text)
        # The commit figures keep the phone's free pages.
        self.assertNotIn("TotalCommittedPages = (totalram + totalswap - ios_avail_phys", text)


if __name__ == "__main__":
    unittest.main()
