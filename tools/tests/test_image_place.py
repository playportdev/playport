# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise where a PE image goes once the window below the furniture ceiling is full, shipped in
madeira-unix 0170 (PLA-418, decision 0128)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0170-virtual-map-an-image-above-the-furniture-ceiling-onc.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_image_place.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_image_place.h"
#include <assert.h>

#define CEILING    0x73ffff0000ull
#define USER_LIMIT 0x7fffffff0000ull
#define DOS_FLOOR  0x10000ull
#define SOCIALCLUB 0x601000ull   /* socialclub.dll's mapped size */

int main(void) {
    uint64_t lo = 0, hi = 0;

    /* Room below the ceiling: the image was placed there, nothing changes. */
    assert(!ppi_image_above_ceiling(0, 0, CEILING, DOS_FLOOR, USER_LIMIT, SOCIALCLUB, &lo, &hi));
    assert(lo == 0 && hi == 0);

    /* The window is full and the cap was ours: above the ceiling, below FEX's band. */
    assert(ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, CEILING, DOS_FLOOR, USER_LIMIT, SOCIALCLUB, &lo, &hi));
    assert(lo == CEILING && hi == 0x7bffffffffull);

    /* A caller's own upper limit holds: no fallback. */
    lo = hi = 0;
    assert(!ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0x7fffffffull, CEILING, DOS_FLOOR, USER_LIMIT, SOCIALCLUB,
                                    &lo, &hi));
    assert(lo == 0 && hi == 0);

    /* Only a full window: another failure is the caller's to see. */
    assert(!ppi_image_above_ceiling(0xc0000018u /* STATUS_CONFLICTING_ADDRESSES */, 0, CEILING, DOS_FLOOR,
                                    USER_LIMIT, SOCIALCLUB, &lo, &hi));
    /* No ceiling, no fallback. */
    assert(!ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, 0, DOS_FLOOR, USER_LIMIT, SOCIALCLUB, &lo, &hi));

    /* A caller's lower limit above the ceiling stays the floor. */
    assert(ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, CEILING, 0x7500000000ull, USER_LIMIT, SOCIALCLUB, &lo, &hi));
    assert(lo == 0x7500000000ull && hi == 0x7bffffffffull);

    /* A user space limit below the band ends the window; one that leaves no room gives none. */
    assert(ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, CEILING, DOS_FLOOR, 0x7800000000ull, SOCIALCLUB, &lo, &hi));
    assert(hi == 0x77ffffffffull);
    assert(!ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, CEILING, DOS_FLOOR, CEILING, SOCIALCLUB, &lo, &hi));
    assert(!ppi_image_above_ceiling(PPI_STATUS_NO_MEMORY, 0, CEILING, 0x7bfffff000ull, USER_LIMIT, SOCIALCLUB,
                                    &lo, &hi));
    return 0;
}
'''


class ImagePlaceTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_image_place.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()
