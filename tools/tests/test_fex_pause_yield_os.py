# SPDX-License-Identifier: GPL-3.0-or-later
"""MADEIRA_FEX_PAUSE=yield-os[:K] (patches/fex 0084, PLA-462): x86 PAUSE stays YIELD, and every K-th PAUSE of a
guest thread makes a swtch_pri Mach trap that lets another thread have the core.

The two headers the patch adds are taken from it as written and compiled on this host: IosPauseOption.h's
parser is checked as is; IosPauseYieldOs.h is run through FEX's own CodeEmitter (from the build's FEX tree,
$PLAYPORT_BUILD/run/fex; skipped without one), and the emitted words are disassembled and compared with the
expected sequence: no flag-setting instruction, x0 and x16 saved and restored around svc #0x80 with x16 = -59.
On an arm64 Mac the emitted code is also run: the count goes up by one per PAUSE and resets at K, the trap is
taken exactly every K-th PAUSE, and x0, x16 and NZCV (the guest's flags) come back unchanged."""
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCHES = ROOT / "patches/fex"
OPTION_H = "FEXCore/include/FEXCore/Utils/IosPauseOption.h"
EMIT_H = "FEXCore/Source/Interface/Core/JIT/IosPauseYieldOs.h"
BUILD = pathlib.Path(os.environ.get("PLAYPORT_BUILD", ROOT / ".work"))
FEX = BUILD / "run/fex"


def new_file(path):
    """The content a fex patch gives a file it creates."""
    for patch in sorted(PATCHES.glob("*.patch")):
        text = patch.read_text(errors="replace")
        marker = f"--- /dev/null\n+++ b/{path}\n"
        if marker not in text:
            continue
        lines = []
        for line in text.split(marker, 1)[1].splitlines()[1:]:  # past the @@ line
            if line.startswith("diff --git") or line == "-- ":
                break
            assert line.startswith("+"), line
            lines.append(line[1:])
        return "\n".join(lines) + "\n"
    raise AssertionError(f"no fex patch creates {path}")


PARSE = r'''
#include "IosPauseOption.h"
#include <cstdio>
int main() {
  struct { const char* In; uint32_t Mode, After; } Cases[] = {
    {nullptr, 0, 0}, {"", 0, 0}, {"yield", 0, 0}, {"wfe", 1, 0}, {"isb", 2, 0}, {"WFE", 0, 0},
    {"yield-os", 3, 128}, {"yield-os:1", 3, 1}, {"yield-os:64", 3, 64}, {"yield-os:256", 3, 256},
    {"yield-os:4095", 3, 4095}, {"yield-os:4096", 0, 0}, {"yield-os:99999999999", 0, 0}, {"yield-os:0", 0, 0},
    {"yield-os:", 0, 0}, {"yield-os:12x", 0, 0}, {"yield-os:-1", 0, 0}, {"yield-osx", 0, 0}, {"yield-os 64", 0, 0},
  };
  int Bad = 0;
  for (auto& C : Cases) {
    auto P = FEX::Ios::ParsePauseOption(C.In);
    if (P.Mode != C.Mode || P.After != C.After) {
      printf("%s: mode %u after %u, want %u %u\n", C.In ? C.In : "(unset)", P.Mode, P.After, C.Mode, C.After);
      Bad++;
    }
  }
  return Bad != 0;
}
'''

# Emits the sequence for State x28, the count at 4096, After K = argv[1], TMP1/TMP2 as ARM64EC's (x10, x11), then
# RET. Prints the words; on arm64 Darwin with argv[2] == "run" also runs them.
EMIT = r'''
#include "IosPauseYieldOs.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(__APPLE__) && defined(__aarch64__)
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>
#endif

namespace FEXCore::Allocator {
void* aligned_alloc(size_t a, size_t s) { return ::aligned_alloc(a, (s + a - 1) / a * a); }
void aligned_free(void* p) { ::free(p); }
void free(void* p) { ::free(p); }
}
namespace fextl {
void ReportAllocationFailure(size_t, size_t) { abort(); }
}

constexpr uint32_t CountOffset = 4096;

#if defined(__APPLE__) && defined(__aarch64__)
struct Regs { uint64_t X0, X10, X16, Nzcv; };
// Calls Code with x28 = State, x0/x16/NZCV as given; returns x0, x10, x16, NZCV after.
static Regs Call(void* Code, void* State, uint64_t X0, uint64_t X16, uint64_t Nzcv) {
  Regs R;
  register uint64_t r0 __asm__("x0") = X0;
  register uint64_t r16 __asm__("x16") = X16;
  register uint64_t r9 __asm__("x9") = Nzcv;
  register void* r28 __asm__("x28") = State;
  register void* r12 __asm__("x12") = Code;
  register uint64_t r10 __asm__("x10");
  __asm__ volatile("msr nzcv, x9\n blr x12\n mrs x9, nzcv\n"
                   : "+r"(r0), "+r"(r16), "+r"(r9), "=r"(r10)
                   : "r"(r28), "r"(r12)
                   : "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x11", "x13", "x14", "x15", "x17", "x30", "memory", "cc");
  R.X0 = r0; R.X10 = r10; R.X16 = r16; R.Nzcv = r9;
  return R;
}
#endif

int main(int argc, char** argv) {
  const uint32_t After = strtoul(argv[1], nullptr, 10);
  alignas(16) static uint8_t Buf[4096];
  ARMEmitter::Emitter E(Buf, sizeof Buf);
  FEXCore::CPU::IosEmitPauseYieldOs(E, ARMEmitter::XReg::x28, CountOffset, After, ARMEmitter::XReg::x10, ARMEmitter::XReg::x11);
  E.ret();
  const size_t Size = E.GetCursorOffset();
  for (size_t i = 0; i < Size; i += 4) {
    uint32_t W;
    memcpy(&W, Buf + i, 4);
    printf("%08x\n", W);
  }
  if (argc < 3 || strcmp(argv[2], "run") != 0) return 0;
#if defined(__APPLE__) && defined(__aarch64__)
  void* Code = mmap(nullptr, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
  if (Code == MAP_FAILED) { perror("mmap"); return 2; }
  pthread_jit_write_protect_np(0);
  memcpy(Code, Buf, Size);
  pthread_jit_write_protect_np(1);
  sys_icache_invalidate(Code, Size);

  alignas(8) static uint8_t State[CountOffset + 8];
  uint64_t& Count = *reinterpret_cast<uint64_t*>(State + CountOffset);
  int Bad = 0, Traps = 0;
  const int Pauses = After * 50 + 7;
  for (int i = 1; i <= Pauses; i++) {
    const uint64_t X0 = 0x1000 + i, X16 = 0x2000 + i, Nzcv = uint64_t(i & 15) << 28;
    const uint64_t Before = Count;
    Regs R = Call(Code, State, X0, X16, Nzcv);
    const bool Trap = i % After == 0;
    Traps += R.X10 == X0; // the trap path keeps x0 in x10, the YIELD path the count
    if (R.X0 != X0 || R.X16 != X16 || R.Nzcv != Nzcv || Count != (Trap ? 0 : Before + 1) || (R.X10 == X0) != Trap) {
      if (Bad++ < 5)
        printf("pause %d: x0 %llx x16 %llx nzcv %llx count %llu x10 %llx\n", i, (unsigned long long)R.X0,
               (unsigned long long)R.X16, (unsigned long long)R.Nzcv, (unsigned long long)Count, (unsigned long long)R.X10);
    }
  }
  printf("ran %d pauses, %d traps\n", Pauses, Traps);
  return Bad != 0 || Traps != Pauses / int(After);
#else
  return 3;
#endif
}
'''


def expected(after):
    return [
        "ldr x10, [x28, #4096]",
        "add x10, x10, #1",
        f"sub x11, x10, #{after}",
        "cbz x11, #16",  # to the trap
        "str x10, [x28, #4096]",
        "yield",
        "b #32",  # past it
        "str xzr, [x28, #4096]",
        "mov x10, x0",
        "mov x11, x16",
        "mov x16, #-59",  # swtch_pri
        "svc #0x80",
        "mov x0, x10",
        "mov x16, x11",
        "ret",
    ]


def compile_(cxx, d, src, out, extra=()):
    subprocess.run([cxx, "-std=c++20", "-O1", "-o", str(out), str(src), *extra], check=True, cwd=d,
                   env={**os.environ, "TMPDIR": str(d)})


class PauseYieldOs(unittest.TestCase):
    def setUp(self):
        self.cxx = shutil.which("clang++") or shutil.which("c++")
        self.assertIsNotNone(self.cxx)
        scratch = BUILD / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch, prefix="fex-pause-")
        self.d = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse(self):
        (self.d / "IosPauseOption.h").write_text(new_file(OPTION_H))
        (self.d / "t.cpp").write_text(PARSE)
        compile_(self.cxx, self.d, self.d / "t.cpp", self.d / "t")
        run = subprocess.run([str(self.d / "t")], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def emitter(self):
        if not (FEX / "CodeEmitter/CodeEmitter/Emitter.h").is_file():
            self.skipTest(f"no FEX tree at {FEX} (pp build)")
        (self.d / "IosPauseYieldOs.h").write_text(new_file(EMIT_H))
        (self.d / "e.cpp").write_text(EMIT)
        exe = self.d / "e"
        compile_(self.cxx, self.d, self.d / "e.cpp", exe,
                 ["-I", str(self.d), "-I", str(FEX / "CodeEmitter"), "-I", str(FEX / "FEXCore/include"),
                  "-I", str(FEX / "FEXHeaderUtils"), "-I", str(FEX / "External/fmt/include"), "-DFMT_HEADER_ONLY", "-w"])
        return exe

    def test_emitted_sequence(self):
        mc = shutil.which("llvm-mc")
        if not mc:
            self.skipTest("no llvm-mc")
        exe = self.emitter()
        for after in (1, 64, 4095):
            words = subprocess.run([str(exe), str(after)], capture_output=True, text=True, check=True).stdout.split()
            hexbytes = " ".join(f"{b:#04x}" for w in words for b in int(w, 16).to_bytes(4, "little"))
            dis = subprocess.run([mc, "--disassemble", "-triple=aarch64"], input=hexbytes, capture_output=True,
                                 text=True, check=True).stdout
            insns = [re.sub(r"\s+", " ", re.sub(r"//.*$", "", l)).strip() for l in dis.splitlines()]
            insns = [i for i in insns if i and not i.startswith(".")]
            self.assertEqual(insns, expected(after), dis)
            flag_setters = [i for i in insns if re.match(r"(adds|subs|cmp|cmn|tst|ands|msr nzcv)\b", i)]
            self.assertEqual(flag_setters, [])

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64", "runs on an arm64 Mac")
    def test_runs_on_darwin(self):
        exe = self.emitter()
        for after in ("1", "3", "128"):
            run = subprocess.run([str(exe), after, "run"], capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
