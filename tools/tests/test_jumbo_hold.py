# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise who may take the boot-time address-space holds, shipped in madeira-unix 0171 (PLA-417,
decision 0129), and check that no title asks for one."""
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
    /* A 32 GB hold for a 32 GB reservation. */
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

    def test_no_title_asks_for_an_address_space_hold(self):
        """No compatibility entry holds address space (decision 0180): elastic reservations make room, so
        RDR2's jumbo-mb=8960 went, and an 8,960 MB hold in every game had left Mewgenics' 1 GiB reservations
        no room (decision 0179). No cohort title does either: The Witcher 3 1.32 played without its
        jumbo-mb=32768 cage-hold=1 (PLA-837)."""
        memory_keys = ("jumbo-mb", "cage-hold", "short-reserve-mb")
        titles = json.loads((ROOT / "app/PlayportKit/Titles/titles.json").read_text())
        compat = json.loads((ROOT / "app/PlayportKit/Titles/compat-defaults.json").read_text())
        configs = {t.get("installDir"): t.get("config", {}) for t in titles["titles"]}
        runtimes = {key: runtime_keys(entry.get("settings", {}).get("runtime", ""))
                    for key, entry in compat["titles"].items()}
        swift = (ROOT / "app/PlayportKit/Sources/PlayportKit/LaunchSettings.swift").read_text()
        every = swift[swift.index("public static let everyGame"):]
        every = every[:every.index("windowsServices:")]
        for key in memory_keys:
            self.assertEqual([name for name, config in configs.items() if key in config], [], key)
            self.assertEqual([name for name, keys in runtimes.items() if key in keys], [], key)
            self.assertNotIn(key, every)


if __name__ == "__main__":
    unittest.main()
