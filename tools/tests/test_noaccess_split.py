# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0279's pp_noaccess_split.h (PLA-516): a 16 KB host page holding a committed
PAGE_NOACCESS 4 KB page beside a page with EXEC is kept inaccessible, so reading the closed page from code on an open
one faults as on x64 Windows; an access to an accessible page of it is completed through an alias, and an access to the
closed page (or a guard, write-copy or write-watch page) is not."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0279-virtual-signal-a-no-access-4-KB-page-beside-code-fau.patch"
HEADER = "build/ntdll-unix/pp_noaccess_split.h"

TEST_C = r'''
#include "pp_noaccess_split.h"
#include <assert.h>

#define C PPNS_COMMITTED
#define NONE (C)
#define RX (C | PPNS_READ | PPNS_EXEC)
#define R (C | PPNS_READ)
#define RW (C | PPNS_READ | PPNS_WRITE)

int main(void) {
    /* Wow.exe's .text: an open code page beside a closed one is split, wherever they sit in the host page. */
    unsigned char code[4] = { RX, NONE, NONE, NONE };
    assert(ppns_host_page_split(code, 4));
    unsigned char code2[4] = { NONE, NONE, RX, RX };
    assert(ppns_host_page_split(code2, 4));
    /* Execute-only (logical EXEC with no read) counts as code. */
    unsigned char xo[4] = { C | PPNS_EXEC, NONE, RX, RX };
    assert(ppns_host_page_split(xo, 4));

    /* Not split: all closed, all open, no code beside the closed page, a guard page (its own fault path), a reserved
     * (uncommitted) page. */
    unsigned char closed[4] = { NONE, NONE, NONE, NONE };
    unsigned char open[4] = { RX, RX, RX, RX };
    unsigned char data[4] = { RW, NONE, R, R };
    unsigned char guard[4] = { RX, C | PPNS_GUARD | PPNS_READ, RX, RX };
    unsigned char reserved[4] = { RX, 0, 0, 0 };
    assert(!ppns_host_page_split(closed, 4) && !ppns_host_page_split(open, 4) && !ppns_host_page_split(data, 4));
    assert(!ppns_host_page_split(guard, 4) && !ppns_host_page_split(reserved, 4));

    /* Completing an access: reads of any accessible page (code included, for FEX's decoder and jump tables); writes
     * only to plain writable pages. */
    assert(ppns_page_allows(RX, 0, 0) && ppns_page_allows(R, 0, 0) && ppns_page_allows(RW, 0, 0));
    assert(ppns_page_allows(C | PPNS_EXEC, 0, 0));
    assert(ppns_page_allows(RW, 1, 0) && !ppns_page_allows(RX, 1, 0) && !ppns_page_allows(R, 1, 0));
    assert(!ppns_page_allows(NONE, 0, 0) && !ppns_page_allows(NONE, 1, 0));           /* the guest's read faults */
    assert(!ppns_page_allows(0, 0, 0) && !ppns_page_allows(C | PPNS_GUARD | PPNS_READ, 0, 0));
    assert(!ppns_page_allows(C | PPNS_READ | PPNS_WRITECOPY, 1, 0) && !ppns_page_allows(RW | PPNS_WRITEWATCH, 1, 0));
    /* FEX translating (its code lock held) reads a committed page a protection change is closing; never writes it,
     * and never reads a reserved or guard page. */
    assert(ppns_page_allows(NONE, 0, 1) && !ppns_page_allows(NONE, 1, 1));
    assert(!ppns_page_allows(0, 0, 1) && !ppns_page_allows(C | PPNS_GUARD, 0, 1));
    return 0;
}
'''


class NoAccessSplitTests(unittest.TestCase):
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
        """mprotect_range keeps a split host page PROT_NONE, and the Mach handler completes only allowed accesses."""
        text = PATCH.read_text()
        self.assertIn("+    if (!guest_image && !set && !clear && prot && ios_host_page_noaccess_split( addr )) prot = PROT_NONE;",
                      text)
        self.assertIn("+        if (!ppns_page_allows( get_page_vprot( (const void *)(uintptr_t)p ), is_write, translator )) return 0;",
                      text)
        self.assertIn("+    translator = teb && *(volatile uint64_t *)((char *)teb + 0x16f8);", text)
        self.assertIn("+    BOOL split = translator && !is_write;", text)
        self.assertIn("+                if (ios_noaccess_split_service( &ns_uc, (void *)fault_addr, thread_teb ))", text)


if __name__ == "__main__":
    unittest.main()
