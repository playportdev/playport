# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise fex 0090's FetchFault.h (PLA-516): an x86 instruction fetch fault reports, as x86-64 Windows
does in ExceptionInformation[1], the first byte of the instruction outside executable memory, not Rip. World of
Warcraft's x64 client makes its code executable a 4 KB page at a time from that address; an instruction at the last
byte of an executable page (run 20261101T172555: 0x1489B3FFF) reported Rip, and the client looped on that page."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/fex/0090-ARM64EC-an-instruction-fetch-fault-reports-the-first.patch"
HEADER = "Source/Windows/Common/FetchFault.h"

TEST_CPP = r'''
#include "FetchFault.h"
#include <cassert>
#include <cstdint>
#include <vector>

struct Range { uint64_t Base, Size; };
static std::vector<Range> Exec;

static Range Query(uint64_t Address) {
  for (auto R : Exec) {
    if (Address >= R.Base && Address < R.Base + R.Size) return R;
  }
  return {0, 0};
}

static uint64_t At(uint64_t Rip) { return FEX::Windows::FetchFaultAddress(Rip, Query); }

int main() {
  // The run's case: page 0x1489B3000 executable, 0x1489B4000 not; the instruction starts at its last byte.
  Exec = {{0x1489B3000, 0x1000}};
  assert(At(0x1489B3FFF) == 0x1489B4000);
  assert(At(0x1489B3FF2) == 0x1489B4000);
  // Rip itself not executable: Rip.
  assert(At(0x1489B4000) == 0x1489B4000);
  assert(At(0x1489B2FF8) == 0x1489B2FF8);
  // Adjacent executable ranges are followed; the fault is past them.
  Exec = {{0x1489B3000, 0x1000}, {0x1489B4000, 0x8}};
  assert(At(0x1489B3FFC) == 0x1489B4008);
  // All 15 bytes executable: no fetch fault in them, Rip as before.
  Exec = {{0x1489B3000, 0x2000}};
  assert(At(0x1489B3FFF) == 0x1489B3FFF);
  // A range ending 15 bytes or more past Rip is not looked past.
  Exec = {{0x1000, 0x10}};
  assert(At(0x1000) == 0x1000);
  assert(At(0x1008) == 0x1010);
  return 0;
}
'''


class FetchFaultTests(unittest.TestCase):
    def test_shipped_header(self):
        cxx = shutil.which("c++")
        self.assertIsNotNone(cxx)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.cpp").write_text(TEST_CPP)
            subprocess.run([cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.cpp")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_the_rethrow_uses_it(self):
        """RethrowGuestException sets ExceptionInformation[1] for a page fault the JIT raised (NoExecOp)."""
        text = PATCH.read_text()
        self.assertIn("+    GuestRec.ExceptionInformation[1] = FEX::Windows::FetchFaultAddress(", text)
        self.assertIn("+                          Fault.TrapNo == FEXCore::X86State::X86_TRAPNO_PF;", text)


if __name__ == "__main__":
    unittest.main()
