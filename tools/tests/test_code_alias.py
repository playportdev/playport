# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0281's pp_code_alias.h (PLA-516): the Mach handler completes a guest read of an
open 4 KB page of a noaccess-split host page from its view's read-only alias (madeira-unix 0280) only when the
alias holds the whole access; the emulator gets the same aliases with bit 63 of the size set (fex 0092)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
ALIAS = ROOT / "patches/madeira-unix/0280-virtual-a-read-only-alias-of-a-mapped-view-with-a-no.patch"
LOOKUP = ROOT / "patches/madeira-unix/0281-signal-a-guest-read-of-an-open-page-of-a-noaccess-sp.patch"
FEX = ROOT / "patches/fex/0092-ARM64EC-read-guest-code-from-Wine-s-read-only-alias-.patch"
HEADER = "build/ntdll-unix/pp_code_alias.h"

TEST_C = r'''
#include "pp_code_alias.h"
#include <assert.h>

int main(void) {
    /* Wow.exe at 0x141800000+0x7354000, its alias at 0x300000000; a freed slot between. */
    struct ppca_entry t[3] = {
        { 0x10000000ull, 0, 0x20000000ull },
        { 0x141800000ull, 0x7354000ull, 0x300000000ull },
        { 0x150000000ull, 0x10000ull, 0x310000000ull },
    };
    assert(ppca_find(t, 3, 0x141800000ull, 4) == 0x300000000ull);
    assert(ppca_find(t, 3, 0x14423a9b0ull, 1) == 0x300000000ull + 0x14423a9b0ull - 0x141800000ull);
    /* The last bytes of the image, and an access that runs past its end. */
    assert(ppca_find(t, 3, 0x141800000ull + 0x7354000ull - 32, 32) != 0);
    assert(ppca_find(t, 3, 0x141800000ull + 0x7354000ull - 16, 32) == 0);
    assert(ppca_find(t, 3, 0x141800000ull + 0x7354000ull, 1) == 0);
    assert(ppca_find(t, 3, 0x1417fffffull, 4) == 0);
    /* A free slot matches nothing; the count bounds the walk. */
    assert(ppca_find(t, 3, 0x10000010ull, 4) == 0);
    assert(ppca_find(t, 2, 0x150000010ull, 4) == 0 && ppca_find(t, 3, 0x150000010ull, 4) == 0x310000010ull);
    assert(ppca_find(t, 0, 0x141800000ull, 4) == 0);
    return 0;
}
'''


class CodeAliasTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(LOOKUP)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_the_runtime_uses_it(self):
        """Wine makes and drops the alias with a mapped view and sends it flagged; FEX reads code there; the handler uses
        it for reads only."""
        alias, lookup, fex = ALIAS.read_text(), LOOKUP.read_text(), FEX.read_text()
        self.assertIn("+#define IOS_CODE_ALIAS_FLAG (1ull << 63)", alias)
        self.assertIn("+        if (view) ios_code_alias_ensure( view );", alias)
        self.assertIn("+    ios_code_alias_drop( view );   /* Playport (PLA-516) */", alias)
        self.assertIn("+    ios_alias_push_all( (uintptr_t)view->base, alias, view->size | IOS_CODE_ALIAS_FLAG );", alias)
        self.assertIn("+    ios_alias_push_all( (uintptr_t)view->base, alias, IOS_CODE_ALIAS_FLAG );", alias)
        self.assertIn("+static constexpr uint64_t kIosCodeReadFlag = 1ull << 63;", fex)
        self.assertIn("+    return IosCodeReadUpdate(PeBase, JitBase, Size & ~kIosCodeReadFlag);", fex)
        self.assertIn("+    const uint64_t AliasRIP = IosCodeReadAddr(RIP);", fex)
        self.assertIn("+    return reinterpret_cast<const uint8_t*>(IosCodeReadAddr(GuestAddr));", fex)
        self.assertIn("+    if (!is_write && (real_alias = ios_code_alias_lookup( addr, bytes )))", lookup)


if __name__ == "__main__":
    unittest.main()
