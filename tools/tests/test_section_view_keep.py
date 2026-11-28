# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0302's pp_section_view.h: mprotect_exec
keeps an ARM64EC section view on its section's own memory even when the view's
4 KB-aligned size is not a multiple of the 16 KB iOS host page, so
mprotect_range's host-page-rounded size stays inside the view instead of
falling through to the JIT pool remap and detaching the view."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0302-virtual-round-section-view-size-to-host-page-in-mpro.patch"
HEADER = "build/ntdll-unix/pp_section_view.h"

TEST_C = r'''
#include "pp_section_view.h"
#include <assert.h>

int main(void) {
    const size_t mask16k = 0x3fff;
    const size_t mask4k = 0xfff;

    /* D2R.exe remapped through a pagefile section: view->size is 4 KB-aligned
     * (0x279b000, not a multiple of 16 KB), while mprotect_range rounds size
     * up to 0x279c000. Both the full view and a sub-range touching the last
     * 16 KB host page stay inside the view. */
    assert(ppsv_range_in_view(0x140080000ull, 0x279c000, 0x140080000ull, 0x279b000, mask16k));
    assert(ppsv_range_in_view(0x142818000ull, 0x4000, 0x140080000ull, 0x279b000, mask16k));
    assert(ppsv_range_in_view(0x140080000ull, 0x4000, 0x140080000ull, 0x279b000, mask16k));

    /* Extending past the rounded host-page end is rejected. */
    assert(!ppsv_range_in_view(0x140080000ull, 0x27a0000, 0x140080000ull, 0x279b000, mask16k));
    assert(!ppsv_range_in_view(0x14281c000ull, 0x4000, 0x140080000ull, 0x279b000, mask16k));
    assert(!ppsv_range_in_view(0x14007c000ull, 0x4000, 0x140080000ull, 0x279b000, mask16k));

    /* A view already aligned to 16 KB (e.g. WoW's 0x2030000) keeps its exact bound. */
    assert(ppsv_range_in_view(0x73f8f70000ull, 0x2030000, 0x73f8f70000ull, 0x2030000, mask16k));
    assert(!ppsv_range_in_view(0x73f8f70000ull, 0x2034000, 0x73f8f70000ull, 0x2030000, mask16k));

    /* On a 4 KB host page, rounding adds nothing. */
    assert(ppsv_range_in_view(0x140080000ull, 0x279b000, 0x140080000ull, 0x279b000, mask4k));
    assert(!ppsv_range_in_view(0x140080000ull, 0x279c000, 0x140080000ull, 0x279b000, mask4k));

    /* Degenerate and overflow cases return 0. */
    assert(!ppsv_range_in_view(0x140080000ull, 0x4000, 0x140080000ull, 0, mask16k));
    assert(!ppsv_range_in_view(0x140080000ull, ~(size_t)0, 0x140080000ull, 0x279b000, mask16k));
    assert(!ppsv_range_in_view(0x140080000ull, 0x4000, 0x140080000ull, ~(size_t)0, mask16k));
    return 0;
}
'''


class SectionViewKeepTests(unittest.TestCase):
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

    def test_the_runtime_uses_it(self):
        """mprotect_exec checks the host-page-rounded section view bound via ppsv_range_in_view."""
        text = PATCH.read_text()
        self.assertIn('+#include "pp_section_view.h"', text)
        self.assertIn(
            "+                && ppsv_range_in_view( (uintptr_t)base, size, (uintptr_t)sv->base, sv->size, host_page_mask ))",
            text,
        )


if __name__ == "__main__":
    unittest.main()
