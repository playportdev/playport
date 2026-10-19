# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise who may take the boot-time address-space holds, shipped in madeira-unix 0171 (PLA-417,
decision 0129), and check which titles ask for the cage hold."""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0171-virtual-hold-the-jumbo-gap-for-the-title-s-own-reser.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_jumbo_hold.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_jumbo_hold.h"
#include <assert.h>

#define MB(n) ((uint64_t)(n) << 20)

int main(void) {
    /* RDR2's hold (jumbo-mb=8960) goes to RDR2's own 8,960 MB reservation. */
    assert(ppj_hold_serves(MB(8960), MB(8960)));
    /* Not to a CEF renderer's 2 GB pool, which took it in run 20261019T173829, nor to the game's 1,175 MB one. */
    assert(!ppj_hold_serves(MB(2048), MB(8960)));
    assert(!ppj_hold_serves(0x49701000ull, MB(8960)));
    /* Nor to one larger than the hold, which never fit. */
    assert(!ppj_hold_serves(MB(8961), MB(8960)));
    /* No hold, nothing to take. */
    assert(!ppj_hold_serves(MB(8960), 0));
    assert(!ppj_hold_serves(0, 0));
    /* The Witcher 3's 32 GB hold for its 32 GB reservation. */
    assert(ppj_hold_serves(MB(32768), MB(32768)));

    /* The cage hold only with cage-hold set. */
    assert(ppj_cage_hold_wanted(1));
    assert(!ppj_cage_hold_wanted(0));
    assert(!ppj_cage_hold_wanted(-1));
    return 0;
}
'''


def runtime_keys(text):
    """`key=value` items at spaces, as LaunchSettings reads a `runtime` string."""
    return dict(item.split("=", 1) for item in text.split() if "=" in item)


class JumboHoldTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_jumbo_hold.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_only_the_witcher_3_asks_for_the_cage_hold(self):
        """The cage hold followed jumbo-mb before decision 0129: every title that set jumbo-mb held it."""
        titles = json.loads((ROOT / "app/PlayportKit/Titles/titles.json").read_text())
        compat = json.loads((ROOT / "app/PlayportKit/Titles/compat-defaults.json").read_text())
        configs = {t.get("installDir"): t.get("config", {}) for t in titles["titles"]}
        self.assertEqual(configs["The Witcher 3"], {"cage-hold": "1", "jumbo-mb": "32768"})
        cage = [name for name, config in configs.items() if "cage-hold" in config]
        self.assertEqual(cage, ["The Witcher 3"])
        runtimes = {key: runtime_keys(entry.get("settings", {}).get("runtime", ""))
                    for key, entry in compat["titles"].items()}
        self.assertEqual(runtimes["app-1174180"], {"jumbo-mb": "8960"})   # RDR2 holds no cage
        self.assertEqual([key for key, keys in runtimes.items() if "cage-hold" in keys], [])


if __name__ == "__main__":
    unittest.main()
