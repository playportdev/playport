# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the short reservations shipped in madeira-unix 0222 (PLA-452): which asks get a real
prefix under madeira.cfg short-reserve-mb, and which commits inside a grant's claim are refused."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0222-virtual-short-reserve-mb-grants-an-unplaceable-reser.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_short_reserve.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_short_reserve.h"
#include <assert.h>

#define MB(n) ((uint64_t)(n) << 20)
#define GB(n) ((uint64_t)(n) << 30)

int main(void) {
    /* The Witcher 3 4.x's 64 and 32 GiB pools under short-reserve-mb = 6144. */
    assert(ppsr_real_size(GB(64), 6144) == MB(6144));
    assert(ppsr_real_size(GB(32), 6144) == MB(6144));
    /* Its 16 GiB pool would be shortened too, were it ever unplaceable. */
    assert(ppsr_real_size(GB(16), 6144) == MB(6144));
    /* An ask the cap and its guard already cover is not shortened: it gains nothing. */
    assert(ppsr_real_size(MB(6144), 6144) == 0);
    assert(ppsr_real_size(MB(6144) + PPSR_GUARD, 6144) == 0);
    assert(ppsr_real_size(MB(6144) + PPSR_GUARD + 0x10000, 6144) == MB(6144));
    /* Off unless the key is set. */
    assert(ppsr_real_size(GB(64), 0) == 0);
    assert(ppsr_real_size(GB(64), -1) == 0);

    const uint64_t base = 0x7800000000ull, real = MB(6144), claimed = GB(64);
    /* The bump cursor's commits within the real part are served. */
    assert(!ppsr_commit_overruns(base, real, claimed, base, MB(2)));
    assert(!ppsr_commit_overruns(base, real, claimed, base + real - MB(2), MB(2)));
    /* The first one past it, and one straddling its end, are refused. */
    assert(ppsr_commit_overruns(base, real, claimed, base + real, MB(2)));
    assert(ppsr_commit_overruns(base, real, claimed, base + real - MB(1), MB(2)));
    /* So is one deep in the claimed tail. */
    assert(ppsr_commit_overruns(base, real, claimed, base + GB(40), MB(2)));
    /* Outside the claim is not the grant's business. */
    assert(!ppsr_commit_overruns(base, real, claimed, base + claimed, MB(2)));
    assert(!ppsr_commit_overruns(base, real, claimed, base - MB(2), MB(2)));
    /* A zero-sized commit counts as one byte; a wrapping one is refused. */
    assert(!ppsr_commit_overruns(base, real, claimed, base, 0));
    assert(ppsr_commit_overruns(base, real, claimed, base + real, 0));
    assert(ppsr_commit_overruns(base, real, claimed, base, ~0ull));
    return 0;
}
'''


class ShortReserveTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_short_reserve.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()
