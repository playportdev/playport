# SPDX-License-Identifier: GPL-3.0-or-later
"""Address pins (PLA-837): compile pp_va_pin.h as madeira-unix 0291 ships it, check the pins of the
two crossed The Witcher 3 1.32 runs, and check that the knob's name stays out of the release app.

A pin, "MiB@0xBASE", holds [base, base + size) from boot and serves the first unhinted, unlimited
reservation of exactly its size.
The dev app's WineHost reads the list from its Runtime keys row (env.PLAYPORT_VA_PINS); build/verify-ipa.py
fails a release executable that names it or links ntdll's setter, madeira_set_va_pins."""
import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
UNIX = ROOT / "patches/madeira-unix"


def added_header():
    patch = next(UNIX.glob("0291-*.patch"))
    section = patch.read_text().split("diff --git a/build/ntdll-unix/pp_va_pin.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_va_pin.h"
#include <assert.h>

#define MB(n) ((uint64_t)(n) << 20)

static struct ppvp pins(const char *spec, int want)
{
    struct ppvp p;
    assert(ppvp_parse(&p, spec) == want);
    return p;
}

int main(void)
{
    struct ppvp p;
    unsigned i;

    /* Run A: the keyed run's addresses (pla802-witcher3-keys: 8 GB at 0x7200000000, 32 GB at
     * 0x7400000000). */
    p = pins("8192@0x7200000000,32768@0x7400000000", 0);
    assert(p.n == 2);
    assert(p.pin[0].size == MB(8192) && p.pin[0].base == 0x7200000000ull && p.pin[0].state == PPVP_SET);
    assert(p.pin[1].size == MB(32768) && p.pin[1].base == 0x7400000000ull && p.pin[1].state == PPVP_SET);
    /* Run B: the no-key run's (pla802-witcher3: [jumbo#1] and [jumbo#2]). */
    p = pins("8192@0x707a350000,32768@0x73ffff0000", 0);
    assert(p.n == 2 && p.pin[0].base == 0x707a350000ull && p.pin[1].base == 0x73ffff0000ull);
    /* Upper-case hex, no 0x, a single pin. */
    p = pins("2048@7077800000", 0);
    assert(p.n == 1 && p.pin[0].base == 0x7077800000ull && p.pin[0].size == MB(2048));
    p = pins("2048@0X7077800000", 0);
    assert(p.n == 1 && p.pin[0].base == 0x7077800000ull);

    /* No knob: no pins. */
    p = pins(0, 0);
    assert(p.n == 0);
    p = pins("", 0);
    assert(p.n == 0);

    /* Malformed: nothing is pinned. */
    {
        static const char *bad[] = {
            "8192", "8192@", "@0x7200000000", "0@0x7200000000", "8192@0x", "8192@0x7200000000,",
            ",8192@0x7200000000", "8192@0x7200000000,,2048@0x7000000000", "8192 @0x7200000000",
            "8192@0x7200000000 ", "-1@0x7200000000", "8192@0x72000g0000", "8192@0x7200001000",
            "8192@0", "1048577@0x7200000000", "16@0xfffffffffff00000", "8192@0x10000000000000000",
            "8192@0x7200000000,8192@0x73ffff0000", "8192@0x7200000000,128@0x71fc000000",
            "64@0x7000000000,64@0x7010000000,64@0x7020000000,64@0x7030000000,64@0x7040000000",
        };
        for (i = 0; i < sizeof bad / sizeof *bad; i++)
        {
            p = pins(bad[i], -1);
            assert(p.n == 0);
        }
    }
    /* Adjacent ranges do not overlap; four pins are the most. */
    p = pins("64@0x7000000000,64@0x7004000000,64@0x7010000000,64@0x7020000000", 0);
    assert(p.n == 4);

    /* Only a held pin serves, once, to a reservation of exactly its size. */
    p = pins("8192@0x7200000000,32768@0x7400000000", 0);
    assert(ppvp_take(&p, MB(8192)) == -1);              /* not held: its boot hold failed */
    p.pin[0].state = p.pin[1].state = PPVP_HELD;
    assert(ppvp_take(&p, MB(2048)) == -1);
    assert(ppvp_take(&p, MB(8192) + 0x10000) == -1);
    assert(ppvp_take(&p, MB(8192) - 0x10000) == -1);
    assert(ppvp_take(&p, MB(32768)) == 1 && p.pin[1].state == PPVP_DONE);
    assert(ppvp_take(&p, MB(32768)) == -1);
    assert(ppvp_take(&p, MB(8192)) == 0 && p.pin[0].state == PPVP_DONE);
    assert(ppvp_take(&p, MB(8192)) == -1);
    /* Two pins of one size serve two reservations, in the list's order. */
    p = pins("64@0x7010000000,64@0x7000000000", 0);
    p.pin[0].state = p.pin[1].state = PPVP_HELD;
    assert(ppvp_take(&p, MB(64)) == 0 && ppvp_take(&p, MB(64)) == 1 && ppvp_take(&p, MB(64)) == -1);
    return 0;
}
'''


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class AddressPins(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_va_pin.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_only_the_dev_host_names_the_knob(self):
        """WineHost reads the knob inside #ifndef PLAYPORT_RELEASE; ntdll never names it, since every string
        in libntdll_unix.a is in the release executable."""
        host = (ROOT / "app/Sources/WineHost/wine_host.c").read_text()
        uses = [m.start() for m in re.finditer(r'"PLAYPORT_VA_PINS"', host)]
        self.assertEqual(len(uses), 1)
        guard = host.rfind("#ifndef PLAYPORT_RELEASE", 0, uses[0])
        self.assertNotEqual(guard, -1)
        self.assertEqual(host.find("#endif", guard, uses[0]), -1)
        patch = next(UNIX.glob("0291-*.patch")).read_text()
        added = "\n".join(line for line in patch.splitlines() if line.startswith("+"))
        self.assertNotIn('"PLAYPORT_VA_PINS"', added)

    def test_release_check_fails_an_executable_that_names_or_sets_the_knob(self):
        verify = load("verify_ipa_va_pin", "build/verify-ipa.py")
        clean = b"\0MADEIRA_NO_DIAGNOSTICS\0playport.log\0"
        syms = ["_pp_guest_pool_install", "_playport_guest_memory_backing"]

        def failures(body, syms=syms):
            nm = subprocess.CompletedProcess(["llvm-nm"], 0, "".join(f"0000000000000000 T {s}\n" for s in syms), "")
            with tempfile.TemporaryDirectory() as d:
                exe = pathlib.Path(d) / "Playport"
                exe.write_bytes(body)
                verify.failures.clear()
                with mock.patch.object(verify.subprocess, "run", return_value=nm), mock.patch("builtins.print"):
                    verify.release_checks(exe, {})
                return list(verify.failures)

        self.assertEqual(failures(clean), [])
        failed = failures(clean + b"PLAYPORT_VA_PINS\0")
        self.assertEqual(len(failed), 1, failed)
        self.assertIn("PLAYPORT_VA_PINS", failed[0])
        # Something in the release app calling the setter links it.
        failed = failures(clean, syms + ["_madeira_set_va_pins"])
        self.assertEqual(len(failed), 1, failed)
        self.assertIn("madeira_set_va_pins", failed[0])


if __name__ == "__main__":
    unittest.main()
