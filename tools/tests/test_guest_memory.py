# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the interval code actually shipped in the Wine patch."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0050-virtual-back-bounded-fresh-guest-data-through-the-host.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_guest_ranges.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


class GuestMemoryRangeTests(unittest.TestCase):
    def test_real_range_code_against_page_model(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_guest_ranges.h").write_text(added_header())
            (d / "test.c").write_text(r'''
#include "pp_guest_ranges.h"
#include <string.h>
static struct pp_guest_range r[256];
static unsigned n;
static unsigned char pages[128];
static void trim(uintptr_t lo, uintptr_t hi) {
    unsigned i = 0;
    while (i < n) {
        uintptr_t a = r[i].lo, b = r[i].hi;
        if (!pp_guest_overlap(r[i], lo, hi)) { i++; continue; }
        uintptr_t oa = a > lo ? a : lo, ob = b < hi ? b : hi;
        if (!pp_guest_trim(r, &n, i, oa, ob)) i++;
    }
}
static void check(void) {
    unsigned char actual[128] = {0};
    assert(n <= 128);
    for (unsigned i = 0; i < n; i++) {
        assert(r[i].lo < r[i].hi);
        assert(!(r[i].lo % 4096) && !(r[i].hi % 4096));
        for (uintptr_t p = r[i].lo / 4096; p < r[i].hi / 4096; p++) {
            assert(p < 128 && !actual[p]);
            actual[p] = 1;
        }
    }
    assert(!memcmp(actual, pages, sizeof pages));
}
int main(void) {
    assert(PP_GUEST_MAX_RANGES * 4096ull == (2ull << 30));
    assert(!pp_guest_overlap((struct pp_guest_range){0,4096},4096,8192));
    for (unsigned seed = 1; seed <= 200; seed++) {
        unsigned rng = seed;
        n = 1; r[0] = (struct pp_guest_range){0,128*4096};
        memset(pages, 1, sizeof pages);
        for (unsigned j = 0; j < 150; j++) {
            rng = rng * 1664525u + 1013904223u;
            unsigned lo = rng % 128;
            rng = rng * 1664525u + 1013904223u;
            unsigned hi = lo + 1 + rng % (128 - lo);
            trim(lo*4096,hi*4096);
            memset(pages+lo, 0, hi-lo);
            check();
        }
    }
    // All prefixes/suffixes survive isolated one-page middle removals.
    n=1; r[0]=(struct pp_guest_range){0,128*4096};
    memset(pages,1,sizeof pages);
    for (unsigned p=1;p<128;p+=2) {
        trim(p*4096,(p+1)*4096); pages[p]=0; check();
    }
    trim(0,128*4096); memset(pages,0,sizeof pages); check(); assert(!n);
    return 0;
}
''')
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
                            "-I", str(d), str(d / "test.c"), "-o", str(d / "test")], check=True,
                           capture_output=True)
            subprocess.run([str(d / "test")], check=True, capture_output=True)

    def test_swift_quota_matches_tracker_bound(self):
        source = (ROOT / "app/Sources/S1Probe/Dev/SharedMemoryBroker.swift").read_text()
        self.assertIn("guestCap: UInt64 = 2 << 30", source)
        self.assertIn("bytes <= guestCap - guestLive", source)
        self.assertIn("if guest { guestMapped += bytes; guestLive += bytes; guestCalls += 1 }", source)
        self.assertIn("guestLive -= bytes", source)
        self.assertIn("#define PP_GUEST_MAX_RANGES (524288u)", added_header())
