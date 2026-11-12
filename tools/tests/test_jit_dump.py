# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0297's pp_jit_dump.h (PLA-555): the JIT pool dump is written only when Settings ›
Developer's JIT pool dump sets MADEIRA_JIT_DUMP; without it neither dump site reads a page of the pool or opens a file,
so a launch that hits a handled fault (The Witcher 3's c000001d) writes no 896 MiB fex-jit-dump.bin and dirties no
untouched pool page (0296)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0297-ntdll-the-JIT-pool-dump-only-when-a-Diagnostics-swit.patch"
HEADER = "build/ntdll-unix/pp_jit_dump.h"

TEST_C = r'''
#include "pp_jit_dump.h"
#include <assert.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define POOL (4 * 65536 + 123)

static int exists(const char *path) { struct stat st; return stat(path, &st) == 0; }

int main(int argc, char **argv) {
    const char *dir = argv[1];
    char want[512], path[512] = "";
    snprintf(want, sizeof want, "%s/fex-jit-dump.bin", dir);
    (void)argc;

    /* What asks for it: set, not empty, not 0. */
    assert(!ppjd_asked(NULL) && !ppjd_asked("") && !ppjd_asked("0"));
    assert(ppjd_asked("1") && ppjd_asked("true"));

    /* Off: a pool no read may touch (PROT_NONE: a read would fault) gives no file and no read. */
    char *none = mmap(NULL, POOL, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(none != MAP_FAILED);
    assert(ppjd_dump(NULL, dir, none, POOL, path, sizeof path) == -2);
    assert(ppjd_dump("", dir, none, POOL, path, sizeof path) == -2);
    assert(ppjd_dump("0", dir, none, POOL, path, sizeof path) == -2);
    assert(!exists(want) && path[0] == 0);

    /* On, with no pool yet: nothing. */
    assert(ppjd_dump("1", dir, NULL, POOL, path, sizeof path) == -2);
    assert(!exists(want));

    /* On: the file is the pool, in MADEIRA_DOCS_DIR. */
    unsigned char *pool = malloc(POOL);
    for (size_t i = 0; i < POOL; i++) pool[i] = (unsigned char)(i * 7 + 3);
    assert(ppjd_dump("1", dir, pool, POOL, path, sizeof path) == POOL);
    assert(strcmp(path, want) == 0);
    FILE *f = fopen(want, "rb");
    assert(f);
    unsigned char *back = malloc(POOL);
    assert(fread(back, 1, POOL, f) == POOL && fgetc(f) == EOF);
    fclose(f);
    assert(memcmp(back, pool, POOL) == 0);

    /* A directory that cannot be written: -1, the path named for the log line. */
    char bad[600];
    snprintf(bad, sizeof bad, "%s/missing", dir);
    assert(ppjd_dump("1", bad, pool, POOL, path, sizeof path) == -1);
    assert(strstr(path, "/missing/fex-jit-dump.bin"));
    return 0;
}
'''


class JitDumpTests(unittest.TestCase):
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
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            docs = d / "docs"
            docs.mkdir()
            subprocess.run([str(d / "t"), str(docs)], check=True)

    def test_both_sites_ask_the_switch_first(self):
        """Each dump site tests the switch before anything reads the pool: the Mach handler's in place of
        madeira_diag_enabled, ill_handler's before 0254's guest-image lookup; both write through ppjd_dump."""
        text = PATCH.read_text()
        self.assertIn("+                    if (cnt == 1 && ppjd_asked(getenv(PPJD_SWITCH)) && "
                      "__sync_bool_compare_and_swap(&dumped, 0, 1))", text)
        self.assertIn("-                    if (cnt == 1 && madeira_diag_enabled && "
                      "__sync_bool_compare_and_swap(&dumped, 0, 1))", text)
        self.assertIn("+        if (ppjd_asked( getenv( PPJD_SWITCH ) ))\n         {\n"
                      "             extern uint64_t ios_jit_reverse_translate(", text)
        self.assertEqual(text.count("ppjd_dump(getenv(PPJD_SWITCH)") + text.count("ppjd_dump( getenv( PPJD_SWITCH )"), 2)
        self.assertNotIn("\n+                        while ((size_t)off < total)", text)

    def test_the_dev_app_sets_the_switch(self):
        """Settings › Developer's JIT pool dump sets MADEIRA_JIT_DUMP in the process environment before the runtime
        starts, and clears it when off; only the dev app has the switch (Dev/)."""
        swift = (ROOT / "app/Sources/S1Probe/Dev/Diagnostics.swift").read_text()
        self.assertIn('static let jitDumpKey = "jitPoolDump"', swift)
        self.assertIn('if UserDefaults.standard.bool(forKey: jitDumpKey) { setenv("MADEIRA_JIT_DUMP", "1", 1) } '
                      'else { unsetenv("MADEIRA_JIT_DUMP") }', swift)
        settings = (ROOT / "app/Sources/S1Probe/Dev/DeveloperSettings.swift").read_text()
        self.assertIn('SettingsSwitchRow(id: "dev:jitDump", title: "JIT pool dump"', settings)


if __name__ == "__main__":
    unittest.main()
