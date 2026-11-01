# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0271's pp_copy_align.h (PLA-514): where in its 16 KB host page a JIT-pool copy of
a PE image starts. A native ARM64 child's copy is the image (decision 0176): World of Warcraft's retail client maps a
read-write view of a section holding its image and views of it at the copy on 64 KB boundaries, which are one memory
with the copy only where both are page aligned. Its copy was shifted 0x3000 so that .data starts a page (run
20261101T102407: "0 bytes of other views made one with it"). In a native child the shift is now taken only when code
shares that page; other processes keep it."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0271-virtual-a-native-ARM64-child-s-image-copy-starts-on-.patch"
HEADER = "build/ntdll-unix/pp_copy_align.h"

TEST_C = r'''
#include "pp_copy_align.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

struct sec { unsigned va, vsize, chars; };
#define X 0x60000020u   /* code, execute, read */
#define R 0x40000040u   /* initialized data, read */
#define W 0xc0000040u   /* initialized data, read, write */

static unsigned char image[0x2000];

static const unsigned char *pe(const struct sec *s, unsigned n) {
    unsigned char *nt = image + 0x80, *t = nt + 24 + 0xf0;
    memset(image, 0, sizeof image);
    image[0] = 'M'; image[1] = 'Z';
    image[0x3c] = 0x80;
    memcpy(nt, "PE\0\0", 4);
    nt[6] = n; nt[20] = 0xf0;
    for (unsigned i = 0; i < n; i++) {
        memcpy(t + i * 40 + 8, &s[i].vsize, 4);
        memcpy(t + i * 40 + 12, &s[i].va, 4);
        memcpy(t + i * 40 + 36, &s[i].chars, 4);
    }
    return image;
}

int main(void) {
    /* World of Warcraft's retail layout on the phone: .data at an RVA 0x1000 past a 16 KB page, far from .text. */
    struct sec wow[] = { { 0x1000, 0x3c20354, X }, { 0x3c22000, 0x6fe000, R }, { 0x4321000, 0x2896ea4, W },
                         { 0x6bc0000, 0x1743e0, R } };
    assert(pp_copy_data_delta(pe(wow, 4), 0x6dcb000, 0) == 0x3000);
    assert(pp_copy_data_delta(pe(wow, 4), 0x6dcb000, 1) == 0);
    /* .text ends in the page .data starts in: the shift stays, native or not. */
    struct sec abut[] = { { 0x1000, 0x50a100, X }, { 0x50b000, 0x1000, W } };
    assert(pp_copy_data_delta(pe(abut, 2), 0x514000, 0) == 0x1000);
    assert(pp_copy_data_delta(pe(abut, 2), 0x514000, 1) == 0x1000);
    /* Code starting later in that page counts too. */
    struct sec after[] = { { 0x1000, 0x2000, R }, { 0x5000, 0x1000, W }, { 0x6000, 0x1000, X } };
    assert(pp_copy_data_delta(pe(after, 3), 0x7000, 1) == 0x3000);
    /* Already on a page, or nothing writable: no shift. */
    struct sec aligned[] = { { 0x1000, 0x3000, X }, { 0x4000, 0x1000, W } };
    assert(pp_copy_data_delta(pe(aligned, 2), 0x5000, 0) == 0);
    struct sec ro[] = { { 0x1000, 0x3000, X }, { 0x5000, 0x1000, R } };
    assert(pp_copy_data_delta(pe(ro, 2), 0x6000, 0) == 0);
    /* A writable section of no virtual size does not count; the lowest writable one decides. */
    struct sec two[] = { { 0x1000, 0x1000, X }, { 0x3000, 0, W }, { 0x9000, 0x1000, W }, { 0x5000, 0x1000, W } };
    assert(pp_copy_data_delta(pe(two, 4), 0xa000, 0) == 0x3000);
    /* Not a PE image. */
    memset(image, 0, sizeof image);
    assert(pp_copy_data_delta(image, sizeof image, 0) == 0);
    assert(pp_copy_data_delta(NULL, 0, 1) == 0);
    return 0;
}
'''


class CopyAlignTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
