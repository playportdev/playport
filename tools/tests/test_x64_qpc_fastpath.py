# SPDX-License-Identifier: GPL-3.0-or-later
"""MADEIRA_X64_QPC_FASTPATH's x64 QueryPerformanceCounter stub (wine-pe 0052, PLA-364).

The stub's bytes (loader.c), struct qpc_state (ntdll_misc.h) and RtlQueryPerformanceCounter's
conversion and resync (time.c) are taken from the patch and run on this x86-64 host, with a
stand-in for the ARM64EC path that uses those same functions:

- for chosen counts (the stub's RDTSC swapped for a load of the count, the only bytes changed),
  the stub gives exactly ticks(count) + offset, and falls back to the export when there is no
  state yet, when a resync is writing (odd seq) or is due, or when the scale is unknown;
- its first call keeps CPUID 15h's shift only when ECX is the counter's frequency (this host's
  CPUID, and a stand-in for FEX's: EAX 1, EBX 2^6, ECX 24, the only other bytes changed);
- with the real RDTSC, stub and EC-path calls interleaved on four threads for 2.5 s never go
  backwards, across the resyncs in that time."""
import importlib.util
import os
import pathlib
import platform
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/wine-pe/0052-ntdll-MADEIRA_X64_QPC_FASTPATH-1-answers-an-x64-modu.patch"


def added_lines(path):
    """The patch's added lines for one file, in order, without the '+'."""
    out, current = [], None
    for line in PATCH.read_text().splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif line.startswith("+") and not line.startswith("+++") and current == path:
            out.append(line[1:])
    return "\n".join(out)


def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i) + len(end)]


def stub_bytes():
    code = block(added_lines("dlls/ntdll/loader.c"), "static const BYTE x64_qpc_code[] =", "};")
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    return [int(b, 16) for b in re.findall(r"0x([0-9a-fA-F]{2})\b", code.split("=", 1)[1])]


PRELUDE = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <cpuid.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <x86intrin.h>
typedef int32_t LONG; typedef int64_t LONGLONG; typedef uint64_t ULONGLONG; typedef uint8_t BYTE; typedef int BOOL;
#define TICKSPERSEC 10000000
#define C_ASSERT(e) _Static_assert(e, #e)
#define FIELD_OFFSET(t, f) __builtin_offsetof(t, f)
#define InterlockedCompareExchange(p, x, c) __sync_val_compare_and_swap(p, c, x)
#define InterlockedExchange(p, x) __atomic_exchange_n(p, x, __ATOMIC_SEQ_CST)
'''

TEST_C = r'''
#include "qpc.c"

static const unsigned char code[] = { STUB_BYTES };
typedef BOOL (__attribute__((ms_abi)) *qpc_fn)(LONGLONG *);
static volatile long fallbacks;
static unsigned shift = 7;     /* the stand-in counter: RDTSC >> shift, about phone CNTFRQ's rate */
static LONGLONG sys_base;

static ULONGLONG count_now(void) { _mm_lfence(); return __rdtsc() >> shift; }
static LONGLONG sys_now(void)    /* NtQueryPerformanceCounter: monotonic time in 100 ns */
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return sys_base + (LONGLONG)ts.tv_sec * TICKSPERSEC + ts.tv_nsec / 100;
}

/* RtlQueryPerformanceCounter's ARM64EC path, with the patch's qpc_to_ticks and qpc_resync. */
static BOOL __attribute__((ms_abi)) ec_qpc(LONGLONG *counter)
{
    ULONGLONG c = count_now();
    LONGLONG offset;
    __sync_fetch_and_add(&fallbacks, 1);
    if (!qpc_state.freq) { *counter = sys_now(); return 1; }   /* the real one reads CNTFRQ here */
    if (!qpc_state.last_sync || c - qpc_state.last_sync >= qpc_state.freq)
    {
        ULONGLONG c0 = count_now(), c1;
        LONGLONG sys = sys_now(), off;
        c1 = count_now();
        off = sys - (LONGLONG)qpc_to_ticks( c0 + (c1 - c0) / 2 );
        offset = qpc_resync( off, c1 );
        c = c1;
    }
    else offset = qpc_state.offset;
    *counter = (LONGLONG)qpc_to_ticks( c ) + offset;
    return 1;
}

#define FAKE_COUNT 1
#define FAKE_CPUID 2

static qpc_fn make_stub(int fake)
{
    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    void *state = &qpc_state, *target = (void *)ec_qpc;
    assert(page != MAP_FAILED);
    memcpy(page, code, sizeof(code));
    memcpy(page + sizeof(code), &state, 8);
    memcpy(page + sizeof(code) + 8, &target, 8);
    if (fake & FAKE_CPUID)
    {   /* mov eax,0x15; xor ecx,ecx; cpuid (0x8f, 9 bytes) -> push 1; pop rax; push 64; pop rbx; push 24; pop rcx */
        static const unsigned char cpuid_seq[] = { 0xb8, 0x15, 0x00, 0x00, 0x00, 0x31, 0xc9, 0x0f, 0xa2 };
        static const unsigned char fixed[] = { 0x6a, 0x01, 0x58, 0x6a, 0x40, 0x5b, 0x6a, 0x18, 0x59 };
        assert(!memcmp(page + 0x8f, cpuid_seq, sizeof(cpuid_seq)));
        memcpy(page + 0x8f, fixed, sizeof(fixed));
    }
    if (fake & FAKE_COUNT)
    {   /* rdtsc; shl rdx,32; mov eax,eax; or rax,rdx (0x1a, 11 bytes) -> mov rax,[r8+0x20] */
        static const unsigned char rdtsc_seq[] = { 0x0f, 0x31, 0x48, 0xc1, 0xe2, 0x20, 0x89, 0xc0, 0x48, 0x09, 0xd0 };
        static const unsigned char load[] = { 0x49, 0x8b, 0x40, 0x20, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
        assert(!memcmp(page + 0x1a, rdtsc_seq, sizeof(rdtsc_seq)));
        memcpy(page + 0x1a, load, sizeof(load));
    }
    return (qpc_fn)page;
}

static ULONGLONG rng = 88172645463325252ULL;
static ULONGLONG next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static void test_chosen_counts(void)
{
    qpc_fn stub = make_stub(FAKE_COUNT);
    LONGLONG v;
    long before;
    /* The stub reads the state at qpc_state's address: copy the fake into it around each call. */
    for (int i = 0; i < 200000; i++)
    {
        ULONGLONG freq = i % 3 ? 24000000 : 1 + next() % 2000000000ULL;
        ULONGLONG last = 1 + next() % (1ULL << 50);
        ULONGLONG c = last + next() % freq;
        LONGLONG offset = (LONGLONG)(next() % (1ULL << 52)) - (1LL << 51);
        unsigned s = i % 2 ? 6 : 0;
        memset(&qpc_state, 0, sizeof(qpc_state));
        qpc_state.freq = freq; qpc_state.last_sync = last; qpc_state.offset = offset;
        qpc_state.seq = 2 * (i % 5); qpc_state.x64_tsc_shift = s;
        qpc_fake_count = c << s;
        before = fallbacks;
        assert(stub(&v) == 1 && fallbacks == before);
        assert(v == (LONGLONG)qpc_to_ticks(c) + offset);
    }
    /* Fallbacks: each goes to the export (which then resyncs the state: set it again each time). */
#define FALLS(seq_, last_, shift_, count_, n) do { \
        memset(&qpc_state, 0, sizeof(qpc_state)); \
        qpc_state.freq = 24000000; qpc_state.offset = 5; qpc_state.seq = seq_; \
        qpc_state.last_sync = last_; qpc_state.x64_tsc_shift = shift_; qpc_fake_count = count_; \
        before = fallbacks; stub(&v); assert(fallbacks == before + n); } while (0)
    FALLS(4, 1000, 0, 1000 + 24000000, 1);   /* a resync due */
    FALLS(4, 1000, 0, 999, 1);               /* a count before the last sync */
    FALLS(3, 1000, 0, 2000, 1);              /* a resync writing */
    FALLS(4, 0, 0, 2000, 1);                 /* no sync yet */
    FALLS(4, 1000, 0xfe, 2000, 1);           /* an unusable scale */
    FALLS(4, 1000, 0, 2000, 0);              /* none of those: the stub answers */
    assert(v == (LONGLONG)qpc_to_ticks(2000) + 5);
}

static void test_scale(void)
{
    qpc_fn stub = make_stub(FAKE_COUNT);
    unsigned a, b, c, d;
    int fits;
    LONGLONG v;
    __cpuid_count(0x15, 0, a, b, c, d);
    fits = a == 1 && b && !(b & (b - 1));   /* else unusable, whatever the frequency */
    /* No CNTFRQ yet: asked again next call. */
    memset(&qpc_state, 0, sizeof(qpc_state)); qpc_state.x64_tsc_shift = 0xff;
    stub(&v); assert(qpc_state.x64_tsc_shift == (fits ? 0xff : 0xfe));
    /* Another frequency: unusable. */
    qpc_state.x64_tsc_shift = 0xff; qpc_state.freq = (ULONGLONG)c + 1;
    stub(&v); assert(qpc_state.x64_tsc_shift == 0xfe);
    /* CPUID's own frequency: its shift. */
    if (c)
    {
        qpc_state.x64_tsc_shift = 0xff; qpc_state.freq = c;
        stub(&v); assert(qpc_state.x64_tsc_shift == (fits ? (unsigned)__builtin_ctz(b) : 0xfe));
    }
    printf("cpuid 15h: eax=%u ebx=%u ecx=%u -> shift %u\n", a, b, c, qpc_state.x64_tsc_shift);

    /* FEX's kind: a 24 Hz counter scaled by 2^6. */
    stub = make_stub(FAKE_COUNT | FAKE_CPUID);
    memset(&qpc_state, 0, sizeof(qpc_state)); qpc_state.x64_tsc_shift = 0xff;
    stub(&v); assert(qpc_state.x64_tsc_shift == 0xff);
    qpc_state.freq = 25; stub(&v); assert(qpc_state.x64_tsc_shift == 0xfe);
    qpc_state.x64_tsc_shift = 0xff; qpc_state.freq = 24; stub(&v); assert(qpc_state.x64_tsc_shift == 6);
}

static qpc_fn live;
static LONGLONG live_end;

static void *reader(void *arg)
{
    LONGLONG last = 0, v;
    (void)arg;
    for (unsigned i = 0; last < live_end; i++)
    {
        if (i & 1) live(&v); else ec_qpc(&v);
        assert(v >= last);
        last = v;
    }
    return NULL;
}

static void test_live(void)
{
    struct timespec t0, t1;
    ULONGLONG c0, c1;
    pthread_t t[4];
    LONGLONG v;
    long before;

    memset(&qpc_state, 0, sizeof(qpc_state));
    clock_gettime(CLOCK_MONOTONIC, &t0); c0 = count_now();
    do clock_gettime(CLOCK_MONOTONIC, &t1); while ((t1.tv_sec - t0.tv_sec) * 1000000000L + t1.tv_nsec - t0.tv_nsec < 50000000L);
    c1 = count_now();
    qpc_state.freq = (c1 - c0) * 20;   /* counts a second */
    qpc_state.x64_tsc_shift = shift;
    sys_base = 1000000000LL;
    live = make_stub(0);
    live(&v);                          /* no sync yet: the export syncs */
    before = fallbacks;
    for (int i = 0; i < 1000; i++) live(&v);
    assert(fallbacks - before < 10);   /* then answered by the stub */
    live_end = v + 25000000;           /* 2.5 s */
    for (int i = 0; i < 4; i++) pthread_create(&t[i], NULL, reader, NULL);
    for (int i = 0; i < 4; i++) pthread_join(t[i], NULL);
    assert(qpc_state.seq >= 6 && !(qpc_state.seq & 1));   /* resynced at least twice more */
    printf("live: freq %llu, %ld EC-path calls, seq %d\n", (unsigned long long)qpc_state.freq, fallbacks, qpc_state.seq);
}

int main(void)
{
    test_chosen_counts();
    test_scale();
    test_live();
    puts("x64 qpc stub: ok");
    return 0;
}
'''


@unittest.skipUnless(platform.machine() in ("x86_64", "AMD64"), "runs the x64 stub natively")
class X64QpcFastpath(unittest.TestCase):
    def test_stub_matches_the_ec_path(self):
        misc = added_lines("dlls/ntdll/ntdll_misc.h")
        time_c = added_lines("dlls/ntdll/time.c")
        state = block(misc, "struct qpc_state\n{", "};") + "\n" + block(misc, "C_ASSERT(", ");")
        source = "\n".join([
            PRELUDE, state,
            # The state, with a fake count right after it at +0x20 for the chosen-count stub.
            "static struct { struct qpc_state s; ULONGLONG count; } qpc_storage __attribute__((aligned(64)));",
            "#define qpc_state (qpc_storage.s)",
            "#define qpc_fake_count (qpc_storage.count)",
            # qpc_to_ticks is a context line in the patch: the one line it changes is its body.
            "static inline ULONGLONG qpc_to_ticks( ULONGLONG c )\n{\n" +
            [l for l in time_c.splitlines() if "return (c / qpc_state.freq)" in l][0] + "\n}",
            # Its closing brace is a context line too.
            block(time_c, "static LONGLONG qpc_resync(", "return off;") + "\n}",
        ])
        code = stub_bytes()
        self.assertEqual(len(code), 0xd0)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "qpc.c").write_text(source)
            (tmp / "test.c").write_text(TEST_C.replace("STUB_BYTES", ", ".join(str(b) for b in code)))
            exe = tmp / "test"
            subprocess.run(["clang", "-std=gnu11", "-O1", "-pthread", "-w", "-o", str(exe), str(tmp / "test.c")],
                           check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("x64 qpc stub: ok", out.stdout)


STAGED = pathlib.Path(os.environ.get("PLAYPORT_BUILD", ROOT / ".work")) / "run/pe/staged/build-arm64ec/dlls"


@unittest.skipUnless(importlib.util.find_spec("pefile"), "reads the built DLLs with pefile")
@unittest.skipUnless((STAGED / "kernel32/arm64ec-windows/kernel32.dll").exists(), "needs a built arm64ec kernel32")
class X64QpcKernel32Import(unittest.TestCase):
    """RDR2 imports QueryPerformanceCounter from KERNEL32. The built KERNEL32's export is the x64
    jmp [rip+d] the loader follows, through an import of kernelbase's QueryPerformanceCounter,
    which kernelbase forwards to ntdll's RtlQueryPerformanceCounter."""

    def test_kernel32_export_is_one_jump_to_ntdll(self):
        import pefile
        loader = added_lines("dlls/ntdll/loader.c")
        self.assertIn("code[0] != 0xff || code[1] != 0x25", loader)
        self.assertIn("target = *(void **)(code + 6 + *(const INT32 *)(code + 2));", loader)

        k32 = pefile.PE(str(STAGED / "kernel32/arm64ec-windows/kernel32.dll"))
        export = next(e for e in k32.DIRECTORY_ENTRY_EXPORT.symbols if e.name == b"QueryPerformanceCounter")
        self.assertIsNone(export.forwarder)
        code = k32.get_data(export.address, 6)
        self.assertEqual(code[:2], b"\xff\x25")
        slot = export.address + 6 + int.from_bytes(code[2:6], "little", signed=True)
        imported = {imp.address - k32.OPTIONAL_HEADER.ImageBase: (dll.dll.lower(), imp.name)
                    for dll in k32.DIRECTORY_ENTRY_IMPORT for imp in dll.imports}
        self.assertEqual(imported.get(slot), (b"kernelbase.dll", b"QueryPerformanceCounter"))

        kb = pefile.PE(str(STAGED / "kernelbase/arm64ec-windows/kernelbase.dll"))
        forward = next(e for e in kb.DIRECTORY_ENTRY_EXPORT.symbols if e.name == b"QueryPerformanceCounter")
        self.assertEqual(forward.forwarder, b"ntdll.RtlQueryPerformanceCounter")


if __name__ == "__main__":
    unittest.main()
