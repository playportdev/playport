# SPDX-License-Identifier: GPL-3.0-or-later
"""MADEIRA_FEX_PAUSE=yield-os[:K] (patches/fex 0084, PLA-462): x86 PAUSE stays YIELD, and every K-th PAUSE of a
guest thread makes a swtch_pri Mach trap that lets another thread have the core.

The two headers the patch adds are taken from it as written and compiled on this host: IosPauseOption.h's
parser is checked as is; IosPauseYieldOs.h is run through FEX's own CodeEmitter (from the build's FEX tree,
$PLAYPORT_BUILD/run/fex; skipped without one), and the emitted words are disassembled and compared with the
expected sequence: no flag-setting instruction, x0 and x16 saved and restored around svc #0x80 with x16 = -59.
The trap path also counts what the trap did (fex 0085, 0087): the traps, those under 2 us at CNTFRQ_EL0 and the ticks
spent in them, in the frame, with no flag set. On an arm64 Mac the emitted code is also run: the count goes up
by one per PAUSE and resets at K, the trap is taken exactly every K-th PAUSE and counted, and x0, x16 and NZCV
(the guest's flags) come back unchanged."""
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


def new_file(path, scratch):
    """The content the fex series gives a file one of its patches creates: that patch's, with each later patch
    that changes the file applied to it (git apply, in scratch)."""
    text = None
    for name in (l.strip() for l in (PATCHES / "series").read_text().splitlines()):
        if not name or name.startswith("#"):
            continue
        patch = PATCHES / name
        body = patch.read_text(errors="replace")
        marker = f"--- /dev/null\n+++ b/{path}\n"
        if marker in body:
            lines = []
            for line in body.split(marker, 1)[1].splitlines()[1:]:  # past the @@ line
                if line.startswith("diff --git") or line == "-- ":
                    break
                assert line.startswith("+"), line
                lines.append(line[1:])
            text = "\n".join(lines) + "\n"
        elif text is not None and f"+++ b/{path}\n" in body:
            tree = scratch / "apply"
            (tree / path).parent.mkdir(parents=True, exist_ok=True)
            (tree / path).write_text(text)
            # Not inside this repository's work tree, where git apply would take paths from its top.
            subprocess.run(["git", "apply", f"--include={path}", str(patch)], cwd=tree, check=True,
                           env={**os.environ, "GIT_CEILING_DIRECTORIES": str(scratch)})
            text = (tree / path).read_text()
    if text is None:
        raise AssertionError(f"no fex patch creates {path}")
    return text


PARSE = r'''
#include "IosPauseOption.h"
#include <cstdio>
int main() {
  struct { const char* In; uint32_t Mode, After, Usec; } Cases[] = {
    {nullptr, 0, 0}, {"", 0, 0}, {"yield", 0, 0}, {"wfe", 1, 0}, {"isb", 2, 0}, {"WFE", 0, 0},
    {"yield-os", 3, 128}, {"yield-os:1", 3, 1}, {"yield-os:64", 3, 64}, {"yield-os:256", 3, 256},
    {"yield-os:4095", 3, 4095}, {"yield-os:4096", 0, 0}, {"yield-os:99999999999", 0, 0}, {"yield-os:0", 0, 0},
    {"yield-os:", 0, 0}, {"yield-os:12x", 0, 0}, {"yield-os:-1", 0, 0}, {"yield-osx", 0, 0}, {"yield-os 64", 0, 0},
    {"yield-os:64:50", 0, 0},
    {"wait-os", 4, 128, 50}, {"wait-os:64", 4, 64, 50}, {"wait-os:64:200", 4, 64, 200}, {"wait-os:1:1", 4, 1, 1},
    {"wait-os:4095:5000", 4, 4095, 5000}, {"wait-os:64:5001", 0, 0}, {"wait-os:64:0", 0, 0}, {"wait-os:64:", 0, 0},
    {"wait-os::50", 0, 0}, {"wait-os:4096:50", 0, 0}, {"wait-os:64:50:1", 0, 0}, {"wait-os:64:5x", 0, 0},
    {"wait-osx", 0, 0}, {"wait-os:", 0, 0},
  };
  int Bad = 0;
  for (auto& C : Cases) {
    auto P = FEX::Ios::ParsePauseOption(C.In);
    if (P.Mode != C.Mode || P.After != C.After || P.Usec != C.Usec) {
      printf("%s: mode %u after %u usec %u, want %u %u %u\n", C.In ? C.In : "(unset)", P.Mode, P.After, P.Usec,
             C.Mode, C.After, C.Usec);
      Bad++;
    }
  }
  struct { uint64_t Freq; uint32_t Ticks; } Short[] = {
    {24000000, 48}, {1000000000, 2000}, {0, 1}, {100000, 1}, {3000000000ull, 4095},
  };
  for (auto& C : Short) {
    if (FEX::Ios::PauseShortTicks(C.Freq) != C.Ticks) {
      printf("short ticks at %llu Hz: %u, want %u\n", (unsigned long long)C.Freq, FEX::Ios::PauseShortTicks(C.Freq), C.Ticks);
      Bad++;
    }
  }
  return Bad != 0;
}
'''

# Emits the sequence for State x28, the counters from 4096, After K = argv[1], a wait of argv[2] us (0: swtch_pri),
# short below argv[3] ticks, TMP1..TMP4 as ARM64EC's (x10..x13), then RET. Prints the words; on arm64 Darwin with
# argv[4] == "run" also runs them, with short at this host's CNTFRQ_EL0 instead.
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
constexpr FEXCore::CPU::IosPauseYieldOsOffsets Off {CountOffset, CountOffset + 8, CountOffset + 16, CountOffset + 24,
                                                    CountOffset + 32};

#if defined(__APPLE__) && defined(__aarch64__)
struct Regs { uint64_t X0, X1, X2, X10, X16, Nzcv; };
// Calls Code with x28 = State, x0/x1/x2/x16/NZCV as given; returns them and x10 after.
static Regs Call(void* Code, void* State, uint64_t X0, uint64_t X1, uint64_t X2, uint64_t X16, uint64_t Nzcv) {
  Regs R;
  register uint64_t r0 __asm__("x0") = X0;
  register uint64_t r1 __asm__("x1") = X1;
  register uint64_t r2 __asm__("x2") = X2;
  register uint64_t r16 __asm__("x16") = X16;
  register uint64_t r9 __asm__("x9") = Nzcv;
  register void* r28 __asm__("x28") = State;
  register void* r15 __asm__("x15") = Code;
  register uint64_t r10 __asm__("x10");
  __asm__ volatile("msr nzcv, x9\n blr x15\n mrs x9, nzcv\n"
                   : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r16), "+r"(r9), "=r"(r10)
                   : "r"(r28), "r"(r15)
                   : "x3", "x4", "x5", "x6", "x7", "x8", "x11", "x12", "x13", "x14", "x17", "x30", "memory", "cc");
  R.X0 = r0; R.X1 = r1; R.X2 = r2; R.X10 = r10; R.X16 = r16; R.Nzcv = r9;
  return R;
}
#endif

int main(int argc, char** argv) {
  const uint32_t After = strtoul(argv[1], nullptr, 10);
  const uint32_t Usec = strtoul(argv[2], nullptr, 10);
  uint32_t ShortTicks = strtoul(argv[3], nullptr, 10);
  const bool Run = argc >= 5 && strcmp(argv[4], "run") == 0;
#if defined(__APPLE__) && defined(__aarch64__)
  if (Run) {
    uint64_t F;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(F));
    ShortTicks = F / 500000 > 4095 ? 4095 : F / 500000;
  }
#endif
  alignas(16) static uint8_t Buf[4096];
  ARMEmitter::Emitter E(Buf, sizeof Buf);
  FEXCore::CPU::IosEmitPauseYieldOs(E, ARMEmitter::XReg::x28, Off, After, Usec, ShortTicks, ARMEmitter::XReg::x10, ARMEmitter::XReg::x11,
                                    ARMEmitter::XReg::x12, ARMEmitter::XReg::x13);
  E.ret();
  const size_t Size = E.GetCursorOffset();
  for (size_t i = 0; i < Size; i += 4) {
    uint32_t W;
    memcpy(&W, Buf + i, 4);
    printf("%08x\n", W);
  }
  if (!Run) return 0;
#if defined(__APPLE__) && defined(__aarch64__)
  void* Code = mmap(nullptr, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
  if (Code == MAP_FAILED) { perror("mmap"); return 2; }
  pthread_jit_write_protect_np(0);
  memcpy(Code, Buf, Size);
  pthread_jit_write_protect_np(1);
  sys_icache_invalidate(Code, Size);

  alignas(8) static uint8_t State[CountOffset + 40];
  uint64_t& Count = *reinterpret_cast<uint64_t*>(State + Off.Count);
  uint64_t& TrapCount = *reinterpret_cast<uint64_t*>(State + Off.Traps);
  uint64_t& ShortCount = *reinterpret_cast<uint64_t*>(State + Off.Short);
  uint64_t& TickCount = *reinterpret_cast<uint64_t*>(State + Off.Ticks);
  int Bad = 0, Traps = 0;
  const int Pauses = After * 50 + 7;
  for (int i = 1; i <= Pauses; i++) {
    const uint64_t X0 = 0x1000 + i, X1 = 0x3000 + i, X2 = 0x4000 + i, X16 = 0x2000 + i, Nzcv = uint64_t(i & 15) << 28;
    const uint64_t Before = Count;
    Regs R = Call(Code, State, X0, X1, X2, X16, Nzcv);
    const bool Trap = i % After == 0;
    Traps += R.X10 == X0; // the trap path keeps x0 in x10, the YIELD path the count
    if (R.X0 != X0 || R.X1 != X1 || R.X2 != X2 || R.X16 != X16 || R.Nzcv != Nzcv || Count != (Trap ? 0 : Before + 1) || (R.X10 == X0) != Trap) {
      if (Bad++ < 5)
        printf("pause %d: x0 %llx x16 %llx nzcv %llx count %llu x10 %llx\n", i, (unsigned long long)R.X0,
               (unsigned long long)R.X16, (unsigned long long)R.Nzcv, (unsigned long long)Count, (unsigned long long)R.X10);
    }
  }
  uint64_t Freq;
  __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(Freq));
  printf("ran %d pauses, %d traps; counted %llu, %llu short, %.2f us each (timer %llu Hz)\n", Pauses, Traps,
         (unsigned long long)TrapCount, (unsigned long long)ShortCount,
         TrapCount ? TickCount * 1e6 / Freq / TrapCount : 0.0, (unsigned long long)Freq);
  // A wait of Usec blocks at least that long: none of them short, and on average no less than Usec.
  const bool WaitOk = !Usec || (ShortCount == 0 && TickCount * 1e6 / Freq >= double(Usec) * TrapCount);
  return Bad != 0 || Traps != Pauses / int(After) || TrapCount != uint64_t(Traps) || ShortCount > TrapCount ||
         (Traps && !TickCount) || !WaitOk;
#else
  return 3;
#endif
}
'''


def expected(after, usec=0, short=48):
    if usec:
        trap = ["mov x12, x1", "mov x13, x2", "mov x0, #0", "mov x1, #3", f"mov x2, #{usec}",
                "mov x16, #-61",  # thread_switch(MACH_PORT_NULL, SWITCH_OPTION_DISPATCH_CONTENTION, usec)
                ]
        restore = ["mov x1, x12", "mov x2, x13"]
    else:
        trap = ["mov x16, #-59"]  # swtch_pri
        restore = []
    tail = [
        "str xzr, [x28, #4096]",
        "mov x10, x0",
        "mov x11, x16",
        "mrs x16, CNTVCT_EL0",
        "str x16, [x28, #4128]",  # Start
        *trap,
        "svc #0x80",
        "mrs x16, CNTVCT_EL0",
        "ldr x0, [x28, #4128]",
        "sub x16, x16, x0",
        "ldr x0, [x28, #4120]",  # Ticks += D
        "add x0, x0, x16",
        "str x0, [x28, #4120]",
        f"sub x16, x16, #{short}",  # Short += D < short
        "lsr x16, x16, #63",
        "ldr x0, [x28, #4112]",
        "add x0, x0, x16",
        "str x0, [x28, #4112]",
        "ldr x0, [x28, #4104]",  # Traps += 1
        "add x0, x0, #1",
        "str x0, [x28, #4104]",
        "mov x0, x10",
        "mov x16, x11",
        *restore,
    ]
    return [
        "ldr x10, [x28, #4096]",
        "add x10, x10, #1",
        f"sub x11, x10, #{after}",
        "cbz x11, #16",  # to the trap
        "str x10, [x28, #4096]",
        "yield",
        f"b #{4 * (len(tail) + 1)}",  # past it
        *tail,
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
        (self.d / "IosPauseOption.h").write_text(new_file(OPTION_H, self.d))
        (self.d / "t.cpp").write_text(PARSE)
        compile_(self.cxx, self.d, self.d / "t.cpp", self.d / "t")
        run = subprocess.run([str(self.d / "t")], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def emitter(self):
        if not (FEX / "CodeEmitter/CodeEmitter/Emitter.h").is_file():
            self.skipTest(f"no FEX tree at {FEX} (pp build)")
        (self.d / "IosPauseYieldOs.h").write_text(new_file(EMIT_H, self.d))
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
        for after, usec, short in ((1, 0, 48), (64, 0, 2000), (4095, 0, 4095), (1, 1, 1), (128, 50, 48),
                                   (4095, 5000, 2000), (64, 65535, 48)):
            words = subprocess.run([str(exe), str(after), str(usec), str(short)], capture_output=True, text=True,
                                   check=True).stdout.split()
            hexbytes = " ".join(f"{b:#04x}" for w in words for b in int(w, 16).to_bytes(4, "little"))
            dis = subprocess.run([mc, "--disassemble", "-triple=aarch64"], input=hexbytes, capture_output=True,
                                 text=True, check=True).stdout
            insns = [re.sub(r"\s+", " ", re.sub(r"//.*$", "", l)).strip() for l in dis.splitlines()]
            insns = [i for i in insns if i and not i.startswith(".")]
            self.assertEqual(insns, expected(after, usec, short), dis)
            flag_setters = [i for i in insns if re.match(r"(adds|subs|cmp|cmn|tst|ands|msr nzcv)\b", i)]
            self.assertEqual(flag_setters, [])

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64", "runs on an arm64 Mac")
    def test_runs_on_darwin(self):
        exe = self.emitter()
        for after, usec in (("1", "0"), ("3", "0"), ("128", "0"), ("1", "50"), ("128", "200")):
            run = subprocess.run([str(exe), after, usec, "0", "run"], capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
