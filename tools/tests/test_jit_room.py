# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the JIT pool's room shipped in madeira-unix 0296 (PLA-846, decision 0184): the
pages between the head and the tail that nothing has used are out of the footprint until first use, and
each is made usable exactly once, before the head or the tail first hands it out, whichever end does."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0296-ntdll-the-JIT-pool-s-untouched-pages-cost-no-footpri.patch"


def added_header():
    section = PATCH.read_text().split("diff --git a/build/ntdll-unix/pp_jit_room.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_jit_room.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define KiB(n) ((size_t)(n) << 10)
#define MiB(n) ((size_t)(n) << 20)
#define POOL MiB(896)

/* What the pool's memory work saw: each run it was asked to make usable. */
static struct { size_t off, len; } runs[64];
static int nruns;
static unsigned long gone_per_run;   /* pages iOS "took back" in each run */

static unsigned long take(void *ctx, size_t off, size_t len)
{
    (void)ctx;
    assert(nruns < 64);
    runs[nruns].off = off;
    runs[nruns].len = len;
    nruns++;
    return gone_per_run;
}

static unsigned char bits[(POOL / PPJR_PAGE + 7) / 8];

static void fresh(struct ppjr *r)
{
    memset(bits, 0, sizeof(bits));
    nruns = 0;
    gone_per_run = 0;
    assert(ppjr_init(r, bits, POOL, PPJR_PAGE) == 0);
}

int main(void)
{
    struct ppjr r;

    /* At the start the whole pool but its first page (the trampolines) is room. */
    fresh(&r);
    assert(ppjr_room_bytes(&r) == POOL - PPJR_PAGE);

    /* The head's first image copy: its pages are made usable once, before use. */
    assert(ppjr_claim(&r, PPJR_PAGE, MiB(1), take, NULL) == MiB(1) / PPJR_PAGE);
    assert(nruns == 1 && runs[0].off == PPJR_PAGE && runs[0].len == MiB(1));
    assert(ppjr_room_bytes(&r) == POOL - PPJR_PAGE - MiB(1));
    /* A range handed out again (a freed range's reuse) costs nothing more. */
    assert(ppjr_claim(&r, PPJR_PAGE, MiB(1), take, NULL) == 0);
    assert(nruns == 1);
    /* An overlapping claim makes only its new pages usable. */
    assert(ppjr_claim(&r, PPJR_PAGE + KiB(512), MiB(1), take, NULL) == KiB(512) / PPJR_PAGE);
    assert(nruns == 2 && runs[1].off == PPJR_PAGE + MiB(1) && runs[1].len == KiB(512));

    /* The tail's carves, from the top down, claimed out of order (two processes racing):
     * each gets exactly its own pages, and a later claim over both only the rest. */
    fresh(&r);
    assert(ppjr_claim(&r, POOL - MiB(32), MiB(16), take, NULL) == MiB(16) / PPJR_PAGE);
    assert(ppjr_claim(&r, POOL - MiB(16), MiB(16), take, NULL) == MiB(16) / PPJR_PAGE);
    assert(nruns == 2);
    assert(runs[0].off == POOL - MiB(32) && runs[0].len == MiB(16));
    assert(runs[1].off == POOL - MiB(16) && runs[1].len == MiB(16));
    assert(ppjr_claim(&r, POOL - MiB(64), MiB(64), take, NULL) == MiB(32) / PPJR_PAGE);
    assert(nruns == 3 && runs[2].off == POOL - MiB(64) && runs[2].len == MiB(32));

    /* A claim with holes in it is made usable a run at a time. */
    fresh(&r);
    ppjr_claim(&r, MiB(1), MiB(1), take, NULL);
    ppjr_claim(&r, MiB(3), MiB(1), take, NULL);
    nruns = 0;
    assert(ppjr_claim(&r, 0, MiB(5), take, NULL) == (MiB(3) - PPJR_PAGE) / PPJR_PAGE);
    assert(nruns == 3);
    assert(runs[0].off == PPJR_PAGE && runs[0].len == MiB(1) - PPJR_PAGE);   /* never the first page */
    assert(runs[1].off == MiB(2) && runs[1].len == MiB(1));
    assert(runs[2].off == MiB(4) && runs[2].len == MiB(1));

    /* Whole pages: a 24 KiB copy at 16 KiB covers two pages; a 1-byte stub at 40 KiB its page. */
    fresh(&r);
    assert(ppjr_claim(&r, PPJR_PAGE, KiB(24), take, NULL) == 2);
    assert(runs[0].off == PPJR_PAGE && runs[0].len == 2 * PPJR_PAGE);
    assert(ppjr_claim(&r, KiB(40), 1, take, NULL) == 0);   /* already in the second page */
    assert(ppjr_claim(&r, KiB(48), 1, take, NULL) == 1);
    assert(runs[1].off == KiB(48) && runs[1].len == PPJR_PAGE);

    /* Nothing outside the pool, and an empty claim, is made usable. */
    assert(ppjr_claim(&r, POOL, MiB(1), take, NULL) == 0);
    assert(ppjr_claim(&r, POOL - PPJR_PAGE, MiB(1), take, NULL) == 1);
    assert(runs[2].off == POOL - PPJR_PAGE && runs[2].len == PPJR_PAGE);
    assert(ppjr_claim(&r, MiB(100), 0, take, NULL) == 0);
    assert(nruns == 3);

    /* Pages iOS took back while they were room are counted at their claim. */
    fresh(&r);
    gone_per_run = 5;
    ppjr_claim(&r, MiB(1), MiB(1), take, NULL);
    ppjr_claim(&r, MiB(8), MiB(1), take, NULL);
    assert(r.taken == 10);
    assert(r.claims == 2 * MiB(1) / PPJR_PAGE);

    /* A pool whose room was never set up (the madvise failed, or a bad size) claims
     * nothing: every page was usable from the bless on, as before. */
    memset(bits, 0, sizeof(bits));
    assert(ppjr_init(&r, bits, POOL + 1, PPJR_PAGE) != 0);
    assert(ppjr_init(&r, bits, POOL, POOL) != 0);
    nruns = 0;
    assert(ppjr_claim(&r, MiB(1), MiB(1), take, NULL) == 0);
    assert(nruns == 0);
    assert(ppjr_room_bytes(&r) == 0);
    {
        struct ppjr never;
        memset(&never, 0, sizeof(never));
        assert(ppjr_claim(&never, MiB(1), MiB(1), take, NULL) == 0);
        assert(nruns == 0);
    }
    return 0;
}
'''


class JitRoomTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_jit_room.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()
