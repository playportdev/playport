# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the backed-page bitmap actually shipped in the Wine patch."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0150-virtual-back-every-fresh-guest-commit-of-a-host-page.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_guest_pages.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


class GuestMemoryPageTests(unittest.TestCase):
    def test_real_page_code_against_page_model(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_guest_pages.h").write_text(added_header())
            (d / "test.c").write_text(r'''
#include "pp_guest_pages.h"
#include <assert.h>
#include <string.h>
static uint64_t bits[PP_GUEST_WORDS];
enum { N = 1024 };   /* model pages: [PP_GUEST_LO, PP_GUEST_LO + N pages) and the window's last N */
static unsigned char lowp[N], highp[N];
static uintptr_t at(unsigned p) { return PP_GUEST_LO + (uintptr_t)p * PP_GUEST_PAGE; }
static uintptr_t top(unsigned p) { return PP_GUEST_HI - (uintptr_t)(N - p) * PP_GUEST_PAGE; }
static void check(void) {
    for (unsigned p = 0; p < N; p++) {
        assert(pp_guest_backed(bits, at(p)) == lowp[p]);
        assert(pp_guest_backed(bits, top(p)) == highp[p]);
    }
    /* The runs a release reports cover the backed pages exactly, each run maximal. */
    unsigned char seen[N] = {0};
    uintptr_t lo = at(0), end, prev = 0;
    while (pp_guest_next_run(bits, &lo, at(N), &end)) {
        assert(lo < end && !(lo % PP_GUEST_PAGE) && !(end % PP_GUEST_PAGE) && lo >= prev);
        assert(lo == at(0) || !lowp[(lo - PP_GUEST_LO) / PP_GUEST_PAGE - 1]);
        assert(end == at(N) || !lowp[(end - PP_GUEST_LO) / PP_GUEST_PAGE]);
        for (uintptr_t a = lo; a < end; a += PP_GUEST_PAGE) seen[(a - PP_GUEST_LO) / PP_GUEST_PAGE] = 1;
        prev = lo = end;
    }
    assert(!memcmp(seen, lowp, N));
}
int main(void) {
    /* The window and its bitmap: 48 GiB of 16 KiB pages, 384 KiB of bits. */
    assert(PP_GUEST_LO == 0x7000000000ull && PP_GUEST_HI == 0x7c00000000ull && PP_GUEST_PAGE == 16384u);
    assert(PP_GUEST_PAGES == 3145728u && sizeof bits == 384u << 10);
    /* Clipping: outside is nothing; partial pages round outward; the ends clamp to the window. */
    uintptr_t lo = 0x6000000000ull, hi = 0x7000000000ull;
    assert(!pp_guest_clip(&lo, &hi));
    lo = PP_GUEST_HI; hi = PP_GUEST_HI + 4096;
    assert(!pp_guest_clip(&lo, &hi));
    lo = PP_GUEST_LO - 4096; hi = PP_GUEST_LO + 4096;
    assert(pp_guest_clip(&lo, &hi) && lo == PP_GUEST_LO && hi == PP_GUEST_LO + PP_GUEST_PAGE);
    lo = PP_GUEST_LO + 3 * 4096; hi = PP_GUEST_LO + 5 * 4096;
    assert(pp_guest_clip(&lo, &hi) && lo == PP_GUEST_LO && hi == PP_GUEST_LO + 2 * PP_GUEST_PAGE);
    lo = PP_GUEST_HI - 4096; hi = ~(uintptr_t)0;
    assert(pp_guest_clip(&lo, &hi) && lo == PP_GUEST_HI - PP_GUEST_PAGE && hi == PP_GUEST_HI);
    assert(!pp_guest_backed(bits, PP_GUEST_LO - 1) && !pp_guest_backed(bits, PP_GUEST_HI));
    /* Random marks and clears, at the window's start and end, against the model. */
    for (unsigned seed = 1; seed <= 200; seed++) {
        unsigned rng = seed;
        memset(bits, 0, sizeof bits); memset(lowp, 0, N); memset(highp, 0, N);
        for (unsigned j = 0; j < 200; j++) {
            rng = rng * 1664525u + 1013904223u;
            unsigned a = (rng >> 8) % N;
            rng = rng * 1664525u + 1013904223u;
            unsigned b = a + 1 + (rng >> 8) % (N - a < 200 ? N - a : 200);
            int set = (rng >> 4) & 1;
            pp_guest_mark(bits, at(a), at(b), set); memset(lowp + a, set, b - a);
            pp_guest_mark(bits, top(a), b == N ? PP_GUEST_HI : top(b), set); memset(highp + a, set, b - a);
            check();
        }
    }
    /* A run that starts mid-word and crosses words, and one ending at the range's end. */
    memset(bits, 0, sizeof bits); memset(lowp, 0, N); memset(highp, 0, N);
    pp_guest_mark(bits, at(60), at(200), 1); memset(lowp + 60, 1, 140); check();
    lo = at(100); uintptr_t end;
    assert(pp_guest_next_run(bits, &lo, at(150), &end) && lo == at(100) && end == at(150));
    lo = at(0);
    assert(pp_guest_next_run(bits, &lo, at(N), &end) && lo == at(60) && end == at(200));
    lo = at(200);
    assert(!pp_guest_next_run(bits, &lo, at(N), &end));
    /* The last page of the window. */
    pp_guest_mark(bits, PP_GUEST_HI - PP_GUEST_PAGE, PP_GUEST_HI, 1);
    lo = PP_GUEST_HI - 4 * PP_GUEST_PAGE;
    assert(pp_guest_next_run(bits, &lo, PP_GUEST_HI, &end) && lo == PP_GUEST_HI - PP_GUEST_PAGE && end == PP_GUEST_HI);
    return 0;
}
''')
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                            "-fsanitize=undefined", "-I", str(d), str(d / "test.c"), "-o", str(d / "test")],
                           check=True, capture_output=True, timeout=60)
            subprocess.run([str(d / "test")], check=True, capture_output=True, timeout=60)
