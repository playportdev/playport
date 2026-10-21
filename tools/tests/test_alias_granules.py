# SPDX-License-Identifier: GPL-3.0-or-later
"""FEX's iOS alias table under its sequence count (fex 0070) and MADEIRA_FEX_BATCH2's granule table
(fex 0071, "alias"), PLA-364.

IosJitAlias.cpp is rebuilt from the fex-port and fex series and compiled on this host with stand-ins
for its Windows and FEXCore headers. A C model of Module.S's IOS_ALIAS_GRANULE_LOOKUP (the same slot
index, key, part marker and empty-slot rule) is then checked against a linear search of the live
entries, for every 4 KB step over a set of images with whole and partial granules, through adds,
retires by size 0, retires by overlap and slot reuse; with the batch off the granule table is not
used; a table that would be more than half full turns the lookup off and is emptied. Four reader threads then
translate through IosJitTranslate (fex 0070's read under the count) while a writer retires and
re-adds one image's slot with another JitBase; no reader may ever see a translation into neither
copy."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILES = ["Source/Windows/ARM64EC/IosJitAlias.cpp", "Source/Windows/ARM64EC/IosMonoBridge.h"]

STUBS = {
    "FEXCore/Utils/LogManager.h": "#pragma once\nnamespace LogMan::Msg { template<typename... A> void EFmt(A&&...) {} "
                                  "template<typename... A> void IFmt(A&&...) {} }\n",
    "windows.h": "#pragma once\nstruct StubTeb { void* ProcessEnvironmentBlock; };\n"
                 "static inline StubTeb* NtCurrentTeb() { static StubTeb t; return &t; }\n",
    "winternl.h": "#pragma once\n",
}

HARNESS = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <atomic>
#include <thread>
#include <vector>

extern "C" {
struct Entry { uint64_t PeBase, JitBase, Size, Pad; };
extern Entry IosAliasEntries[];
extern volatile int IosAliasCount;
extern volatile uint64_t IosAliasGen;
struct Granule { uint64_t Key, Delta; };
extern Granule IosAliasGranules[];
uint32_t IosFexBatch2 = 0;
int BTCpu64IosAddAliasMapping(uint64_t, uint64_t, uint64_t);
int IosAliasGranulesEnable(void);
uint64_t IosJitTranslate(uint64_t);
uint64_t ios_fex_rip_from_hostpc(uint64_t, uint64_t) { return 0; }
void ios_fex_mono_bridge_publish(void*) {}
void ios_fex_mono_report_armed(uint64_t, uint64_t) {}
}

static uint64_t linear(uint64_t x) {
  for (int i = IosAliasCount - 1; i >= 0; i--)
    if (x - IosAliasEntries[i].PeBase < IosAliasEntries[i].Size) return x - IosAliasEntries[i].PeBase + IosAliasEntries[i].JitBase;
  return x;
}

/* Module.S's IOS_ALIAS_GRANULE_LOOKUP: 1 = answered (x9 is the result), 0 = falls through to the walk. */
static int granule_lookup(uint64_t x9, uint64_t* out) {
  if (!(IosFexBatch2 & 1)) return 0;
  uint64_t gen = IosAliasGen;
  if (gen & 1) return 0;
  uint64_t key = (x9 >> 16) + 1;
  uint64_t x17 = (key & ((1ull << 40) - 1)) | (gen << 40);
  uint64_t off = (x17 & 32767) << 4;
  for (;;) {
    const Granule* s = (const Granule*)((const char*)IosAliasGranules + off);
    if (!s->Key) { *out = x9; return 1; }
    if (((s->Key ^ x17) << 24) == 0) {
      uint64_t d = s->Delta;
      if ((((IosAliasGen ^ (x17 >> 40)) << 40)) != 0) return 0;
      if (d & 1) return 0;
      *out = x9 + d;
      return 1;
    }
    off = (off + 16) & 0x7fff0;
  }
}

static void check_all(int expect_answers) {
  int answered = 0, fell = 0;
  for (int i = 0; i < IosAliasCount; i++) {
    uint64_t pb = IosAliasEntries[i].PeBase, sz = IosAliasEntries[i].Size ? IosAliasEntries[i].Size : 0x40000;
    for (uint64_t x = (pb > 0x20000 ? pb - 0x20000 : pb); x < pb + sz + 0x20000; x += 0x1000) {
      uint64_t got;
      if (granule_lookup(x, &got)) { answered++; if (got != linear(x)) { printf("x=%#llx got %#llx want %#llx\n", (unsigned long long)x, (unsigned long long)got, (unsigned long long)linear(x)); assert(0); } }
      else fell++;
    }
  }
  (void)fell;
  if (expect_answers) assert(answered > 0);
  else assert(answered == 0);
}

int main() {
  /* batch off: nothing is kept, the lookup never answers */
  assert(BTCpu64IosAddAliasMapping(0x180000000ull, 0x300000000ull, 0x30000) == 1);
  check_all(0);
  /* on: what is listed so far is built in */
  assert(IosAliasGranulesEnable() > 0);
  check_all(1);
  /* whole and partial granules, an unaligned base, adjacent images */
  assert(BTCpu64IosAddAliasMapping(0x190000000ull, 0x310004000ull, 0x2C000) == 1);
  assert(BTCpu64IosAddAliasMapping(0x190030000ull, 0x320000000ull, 0x10000) == 1);
  assert(BTCpu64IosAddAliasMapping(0x1a0004000ull, 0x330000000ull, 0x24000) == 1);
  check_all(1);
  { uint64_t got; assert(!granule_lookup(0x1a0008000ull, &got)); assert(granule_lookup(0x1a0010000ull, &got) && got == 0x33000c000ull); }
  /* retire by size 0, then reuse of the slot by another image */
  assert(BTCpu64IosAddAliasMapping(0x190000000ull, 0x310004000ull, 0) == 1);
  check_all(1);
  assert(BTCpu64IosAddAliasMapping(0x1b0000000ull, 0x340000000ull, 0x50000) == 1);
  check_all(1);
  /* an overlapping image retires the old one */
  assert(BTCpu64IosAddAliasMapping(0x1b0020000ull, 0x350000000ull, 0x50000) == 1);
  check_all(1);
  assert(!(IosAliasGen & 1));
  /* more than half the slots: the lookup turns itself off, the walk stays right */
  assert(BTCpu64IosAddAliasMapping(0x200000000ull, 0x400000000ull, 16385ull << 16) == 1);
  assert(!(IosFexBatch2 & 1));
  for (int i = 0; i < 32768; i++) assert(!IosAliasGranules[i].Key);   /* emptied: a stale reader finds nothing */
  check_all(0);

  /* readers against a writer flipping one slot between two copies */
  const uint64_t pe = 0x500000000ull, a = 0x600000000ull, b = 0x700000000ull, sz = 0x10000;
  std::atomic<bool> stop{false};
  std::atomic<long> reads{0};
  std::vector<std::thread> readers;
  for (int t = 0; t < 4; t++)
    readers.emplace_back([&] {
      while (!stop.load()) {
        uint64_t got = IosJitTranslate(pe + 0x100);
        assert(got == pe + 0x100 || got == a + 0x100 || got == b + 0x100);
        reads++;
      }
    });
  for (int i = 0; i < 20000; i++) {
    BTCpu64IosAddAliasMapping(pe, (i & 1) ? b : a, sz);
    BTCpu64IosAddAliasMapping(pe, (i & 1) ? b : a, 0);
  }
  stop = true;
  for (auto& r : readers) r.join();
  printf("ok, %ld reads\n", reads.load());
  return 0;
}
'''


def rebuild(directory):
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
    for target in ["fex-port", "fex"]:
        pdir = ROOT / "patches" / target
        for name in (l.strip() for l in (pdir / "series").read_text().splitlines()):
            if not name or name.startswith("#"):
                continue
            text = (pdir / name).read_text(errors="replace")
            for f in FILES:
                if f"b/{f}" in text:
                    subprocess.run(["git", "apply", f"--include={f}", str(pdir / name)], cwd=directory, check=True)


class AliasGranuleTests(unittest.TestCase):
    def test_granules_and_sequence_count(self):
        cxx = shutil.which("c++")
        self.assertIsNotNone(cxx)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            rebuild(d)
            src = d / FILES[0]
            text = src.read_text().replace('__asm__ volatile("yield")', '__asm__ volatile("pause")')
            src.write_text(text)
            for name, body in STUBS.items():
                (d / "inc" / name).parent.mkdir(parents=True, exist_ok=True)
                (d / "inc" / name).write_text(body)
            (d / "t.cpp").write_text(HARNESS)
            exe = d / "t"
            subprocess.run([cxx, "-std=c++20", "-O1", "-g", "-pthread", "-DFEX_IOS_HOST", "-I", str(d / "inc"),
                            "-I", str(src.parent), "-o", str(exe), str(src), str(d / "t.cpp")], check=True,
                           env={**os.environ, "TMPDIR": str(d)})
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
