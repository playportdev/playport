# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0276's pp_image_sync.h (PLA-516): a protection change on a page of ntdll's
writable sections copies into ntdll's JIT-pool copy only the 8-byte words written while the page was open, so the
copy's live globals (the loader's hash_table, node_ntdll, tls_dirs beside the Wow64PrepareForException pointer a
guest hooks) are not overwritten with the image's stale page; every other module's page, and a region with nothing
kept, is copied whole, as before."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0276-virtual-a-protection-change-on-a-page-of-ntdll-s-dat.patch"
HEADER = "build/ntdll-unix/pp_image_sync.h"

TEST_C = r'''
#include "pp_image_sync.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

#define PAGE 0x1000

static unsigned char image[2 * PAGE] __attribute__((aligned(PAGE)));
static unsigned char copy[2 * PAGE];
static struct ppis_table t;

int main(void) {
    /* Opening: the loader's PAGE_READWRITE and a guest's PAGE_EXECUTE_READWRITE, with or without modifiers.
     * Restoring (write-copy, read-only, read-execute) is not opening. */
    assert(ppis_opens(0x04) && ppis_opens(0x40) && ppis_opens(0x104));
    assert(!ppis_opens(0x08) && !ppis_opens(0x02) && !ppis_opens(0x20) && !ppis_opens(0x80) && !ppis_opens(0x01));

    /* The ntdll .data page: the copy holds live globals the image does not (stale image). */
    memset(image, 0x11, PAGE);
    memset(copy, 0x11, PAGE);
    memset(copy + 0x100, 0xaa, 0x80);                  /* hash_table, node_ntdll: live only in the copy */
    assert(ppis_keep(&t, image, PAGE));                /* the guest opens the page */
    uint64_t hook = 0x13f351460ull;
    memcpy(image + 0x5a0, &hook, 8);                   /* and writes its hook at the image's address */
    unsigned char *was = ppis_take(&t, image, PAGE);   /* then restores it */
    assert(was && !ppis_take(&t, image, PAGE));        /* taken once */
    assert(ppis_merge(copy, image, was, PAGE) == 8);
    assert(!memcmp(copy + 0x5a0, &hook, 8));           /* the hook reached the copy */
    for (int i = 0x100; i < 0x180; i++) assert(copy[i] == 0xaa);   /* the live globals are as they were */
    assert(ppis_written(image, was, 0x5a0) && !ppis_written(image, was, 0x100) && !ppis_written(image, was, 0x598));
    free(was);

    /* A pointer written over a relocated one is copied whole, even where some bytes are unchanged. */
    memset(image, 0, PAGE);
    uint64_t relocated = 0x10a1801234ull, stale = 0x180001234ull, written = 0x180009999ull;
    memcpy(copy + 0x40, &relocated, 8);
    memcpy(image + 0x40, &stale, 8);
    assert(ppis_keep(&t, image, PAGE));
    memcpy(image + 0x40, &written, 8);
    was = ppis_take(&t, image, PAGE);
    assert(ppis_merge(copy, image, was, PAGE) == 8);
    assert(!memcmp(copy + 0x40, &written, 8));
    free(was);

    /* Only the exact region opened is matched; a region never opened has nothing kept. */
    assert(ppis_keep(&t, image, PAGE));
    assert(!ppis_take(&t, image, 2 * PAGE) && !ppis_take(&t, image + PAGE, PAGE));
    free(ppis_take(&t, image, PAGE));

    /* Reopening the same region keeps the newer bytes; the table holds PPIS_SNAPS regions, oldest out first. */
    image[0] = 1;
    assert(ppis_keep(&t, image, PAGE));
    image[0] = 2;
    assert(ppis_keep(&t, image, PAGE));
    image[0] = 3;
    was = ppis_take(&t, image, PAGE);
    assert(was && was[0] == 2);
    free(was);
    static unsigned char many[PPIS_SNAPS + 1][16];
    for (int i = 0; i <= PPIS_SNAPS; i++) assert(ppis_keep(&t, many[i], 16));
    assert(!ppis_take(&t, many[0], 16));
    for (int i = 1; i <= PPIS_SNAPS; i++) { was = ppis_take(&t, many[i], 16); assert(was); free(was); }

    /* Over PPIS_MAX_BYTES nothing is kept: the caller copies the whole region, as before. */
    static unsigned char big[PPIS_MAX_BYTES + PAGE];
    assert(!ppis_keep(&t, big, sizeof big) && !ppis_keep(&t, big, 0));

    /* A trailing part of a word is compared byte by byte. */
    unsigned char s[11] = {0}, w[11] = {0}, d[11] = {0};
    s[10] = 7;
    assert(ppis_merge(d, s, w, 11) == 1 && d[10] == 7);
    return 0;
}
'''


class ImageSyncTests(unittest.TestCase):
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
            subprocess.run([str(d / "t")], check=True)

    def test_the_sync_uses_it(self):
        """NtProtectVirtualMemory keeps on open and merges on restore for a page of ntdll's writable sections only,
        touches only written words after, and syncs the calling process's own copy."""
        text = PATCH.read_text()
        self.assertIn('+                                 "ntdll.dll" ))', text)
        self.assertIn("+                        if (ppis_opens( new_prot )) kept = ppis_keep( &ios_image_sync, base, size );",
                      text)
        self.assertIn("+                            size_t n = ppis_merge( (unsigned char *)jit_rw_dest, base, was, size );",
                      text)
        self.assertIn("+                    if (idx != sync_pick) continue;", text)
        self.assertIn("+        if (ios_jit_mappings[i].owner_peb == owner) return i;", text)


if __name__ == "__main__":
    unittest.main()
