# SPDX-License-Identifier: GPL-3.0-or-later
"""A SocialClubHelper.exe --type= child under the Social Club layout (PLA-865): compile pp_sc_child.h as
madeira-unix 0298 ships it and check which children start, and that NtCreateUserProcess asks it for every
child, not only when single-process is enabled.

The layout holds one CEF process's PartitionAlloc pools; a child's 32 GiB ask is refused there, its
chrome_elf traps, and its browser starts it again (1,237 storage-service starts in 90 s with Social Club
2.4.0.302, which the single-process guard does not verify). So under the layout every child is refused at
its start, as a verified helper's child already was; without the layout an unverified child starts."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UNIX = ROOT / "patches/madeira-unix"


def patch():
    return next(UNIX.glob("0298-*.patch")).read_text()


def added_file(name):
    section = patch().split(f"diff --git a/build/ntdll-unix/{name}", 1)[1].split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_sc_child.h"
#include <assert.h>

int main(void)
{
    unsigned n, logged = 0;

    /* verified, layout */
    assert(pp_sc_child_verdict(1, 1) == PPSCC_REFUSE_VERIFIED);
    assert(pp_sc_child_verdict(1, 0) == PPSCC_REFUSE_VERIFIED);
    assert(pp_sc_child_verdict(0, 1) == PPSCC_REFUSE_LAYOUT);   /* census4's storage service */
    assert(pp_sc_child_verdict(0, 0) == PPSCC_START);           /* no layout: the multi-process policy */

    /* census4's 1,237 starts would log 4 + 4 lines (256, 512, 768, 1024). */
    for (n = 1; n <= 1237; n++) logged += pp_sc_child_logged(n);
    assert(logged == 8);
    assert(pp_sc_child_logged(1) && pp_sc_child_logged(4) && !pp_sc_child_logged(5));
    assert(pp_sc_child_logged(256) && !pp_sc_child_logged(257));
    return 0;
}
'''


class ScChild(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_sc_child.h").write_text(added_file("pp_sc_child.h"))
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_every_child_is_asked(self):
        """The verdict sits outside the single-process gate: a dev build's PLAYPORT_SC_SINGLE=0 must not
        bring the loop back under the layout."""
        body = patch().split("diff --git a/build/ntdll-unix/process_ios.c", 1)[1].split("diff --git ", 1)[0]
        after = "\n".join(line[1:] for line in body.splitlines()
                          if not line.startswith("-") and not line.startswith("@@"))
        gate = after.index("if (kind != SC_NOT_HELPER)\n")
        single = after.index("if (playport_sc_single_enabled())", gate)
        verdict = after.index("pp_sc_child_verdict( verified, pp_sc_layout_ready() )", gate)
        close_single = after.index("\n            }\n", single)
        self.assertLess(close_single, verdict, "the verdict runs after, not inside, the single-process gate")
        self.assertIn("int pp_sc_layout_ready(void) { return ppsc_ready; }", patch())


if __name__ == "__main__":
    unittest.main()
