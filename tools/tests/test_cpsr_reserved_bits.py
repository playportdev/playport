# SPDX-License-Identifier: GPL-3.0-or-later
"""The reserved CPSR bits masking ported from WineHQ 7fb24b7: the write side (patches/madeira-unix
0161) and wineserver's Mach capture, the read side (0162)."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/madeira-unix/0161-ntdll-unix-ignore-attempts-to-set-reserved-CPSR-bits.patch"
READ_PATCH = REPO / "patches/madeira-unix/0162-wineserver-report-only-the-user-CPSR-bits-from-the-M.patch"

# wine-11.20's dlls/ntdll/unix/unix_private.h, which the *_ios.c replacements include.
CPSR_USER_MASK = 0xf620fc30


def added_lines(patch):
    return [line[1:] for line in patch.read_text().splitlines()
            if line.startswith("+") and not line.startswith("+++")]


def compile_and_run(source_text):
    work = REPO / ".work"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cpsr-reserved-bits-", dir=work) as tmp:
        root = Path(tmp)
        source = root / "test.c"
        source.write_text(source_text)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-o", str(root / "test"), str(source)], check=True)
        subprocess.run([str(root / "test")], check=True)


def added_line(added, start):
    lines = [line.strip() for line in added if line.strip().startswith(start)]
    if len(lines) != 1:
        raise AssertionError(f"{start!r}: {len(lines)} added lines")
    return lines[0]


class CpsrReservedBits(unittest.TestCase):
    def test_masking(self):
        added = added_lines(PATCH)
        # save_context, NtSetContextThread, set_thread_wow64_context, context_to_server (ARM, ARM64).
        self.assertEqual(sum("& cpsr_user_mask;" in line for line in added), 5)
        # restore_context and usr2_handler.
        self.assertEqual(sum("& cpsr_host_mask)" in line for line in added), 2)
        host_mask = added_line(added, "static const ULONG cpsr_host_mask")
        save = added_line(added, "context->Cpsr = PSTATE_sig(sigcontext)")
        restore = added_line(added, "PSTATE_sig(sigcontext) =")
        set_frame = added_line(added, "frame->cpsr  =")
        usr2 = added_line(added, "PSTATE_sig(context) =")
        compile_and_run(f'''#include <assert.h>
#include <stdint.h>
typedef uint32_t ULONG;
typedef struct {{ ULONG Cpsr; }} CONTEXT;
typedef struct {{ uint32_t cpsr; }} ucontext_t;
struct syscall_frame {{ ULONG cpsr; }};
#define PSTATE_sig(context) ((context)->cpsr)
static const ULONG cpsr_user_mask = {CPSR_USER_MASK:#x};
{host_mask}

static ULONG save(uint32_t pstate)
{{
    ucontext_t uc = {{ pstate }}, *sigcontext = &uc;
    CONTEXT ctx, *context = &ctx;
    {save}
    return ctx.Cpsr;
}}

static uint32_t restore(uint32_t pstate, ULONG cpsr)
{{
    ucontext_t uc = {{ pstate }}, *sigcontext = &uc;
    const CONTEXT ctx = {{ cpsr }}, *context = &ctx;
    {restore}
    return uc.cpsr;
}}

static ULONG set_context(ULONG cpsr)
{{
    struct syscall_frame f, *frame = &f;
    const CONTEXT ctx = {{ cpsr }}, *context = &ctx;
    {set_frame}
    return f.cpsr;
}}

static uint32_t usr2(uint32_t pstate, ULONG frame_cpsr)
{{
    ucontext_t uc = {{ pstate }}, *context = &uc;
    const struct syscall_frame f = {{ frame_cpsr }}, *frame = &f;
    {usr2}
    return uc.cpsr;
}}

int main(void)
{{
    /* A host state with NZCV, DAIF, SSBS and bits outside the user mask set. */
    const uint32_t host = 0x60000000 | 0x3c0 | 0x1000 | 0x00500000 | 0x01000000;
    const ULONG orig = save(host);
    uint32_t i;

    assert((orig & ~cpsr_user_mask) == 0);
    assert(orig == (host & cpsr_user_mask));
    /* WineHQ's test: set ~orig, read it back, only the user bits flipped. */
    assert((orig ^ set_context(~orig)) == cpsr_user_mask);
    /* The host bits outside the user mask, and SSBS, are the interrupted state's. */
    assert((restore(host, ~orig) & cpsr_host_mask) == (host & cpsr_host_mask));
    assert((restore(0, 0xffffffff) & cpsr_host_mask) == 0);
    assert((restore(host, ~orig) & ~cpsr_host_mask) == (~orig & ~cpsr_host_mask));
    assert(restore(host, orig) == host);
    /* What FEX's ARM64EC and WoW64 modules write: NZCV and bit 21 (the x86 trap flag). */
    for (i = 0; i < 32; i++)
    {{
        ULONG fex = ((i & 0xf) << 28) | ((i & 0x10) ? 1u << 21 : 0);
        assert(set_context(fex) == fex);
        assert(save(restore(host, fex)) == (fex | (host & 0x1000)));
        assert((usr2(host, set_context(fex)) & ~cpsr_host_mask) == fex);
        assert((usr2(host, set_context(fex)) & cpsr_host_mask) == (host & cpsr_host_mask));
    }}
    return 0;
}}
''')


    def test_read_side(self):
        added = added_lines(READ_PATCH)
        mask = added_line(added, "#define IOS_CPSR_USER_MASK")
        self.assertEqual(int(mask.split()[2], 16), CPSR_USER_MASK)
        # ios_fill_thread_context: the Mach state, and the syscall frame of a thread in a syscall.
        self.assertEqual(sum("& IOS_CPSR_USER_MASK;" in line for line in added), 2)
        mach = added_line(added, "native->ctl.arm64_regs.pstate = arm.__cpsr")
        frame = added_line(added, "native->ctl.arm64_regs.pstate = *(uint32_t *)(f + IOS_SCF_CPSR)")
        save = added_line(added_lines(PATCH), "context->Cpsr = PSTATE_sig(sigcontext)")
        set_frame = added_line(added_lines(PATCH), "frame->cpsr  =")
        compile_and_run(f'''#include <assert.h>
#include <stdint.h>
#include <string.h>
typedef uint32_t ULONG;
typedef struct {{ ULONG Cpsr; }} CONTEXT;
typedef struct {{ uint32_t cpsr; }} ucontext_t;
typedef struct {{ uint32_t __cpsr; }} arm_thread_state64_t;
struct syscall_frame {{ ULONG cpsr; }};
struct context_data {{ struct {{ struct {{ uint32_t pstate; }} arm64_regs; }} ctl; }};
#define PSTATE_sig(context) ((context)->cpsr)
#define IOS_SCF_CPSR 0x108
static const ULONG cpsr_user_mask = {CPSR_USER_MASK:#x};
{mask}

/* What the thread itself reports (0161's save_context). */
static ULONG save(uint32_t pstate)
{{
    ucontext_t uc = {{ pstate }}, *sigcontext = &uc;
    CONTEXT ctx, *context = &ctx;
    {save}
    return ctx.Cpsr;
}}

static ULONG set_context(ULONG cpsr)
{{
    struct syscall_frame fr, *frame = &fr;
    const CONTEXT ctx = {{ cpsr }}, *context = &ctx;
    {set_frame}
    return fr.cpsr;
}}

static uint32_t read_mach(uint32_t cpsr)
{{
    arm_thread_state64_t arm = {{ cpsr }};
    struct context_data data, *native = &data;
    {mach}
    return data.ctl.arm64_regs.pstate;
}}

static uint32_t read_frame(uint32_t cpsr)
{{
    _Alignas(8) unsigned char f[0x330] = {{ 0 }};
    struct context_data data, *native = &data;
    memcpy( f + IOS_SCF_CPSR, &cpsr, sizeof(cpsr) );
    {frame}
    return data.ctl.arm64_regs.pstate;
}}

int main(void)
{{
    /* A host state with NZCV, DAIF, SSBS and bits outside the user mask set. */
    const uint32_t host = 0x60000000 | 0x3c0 | 0x1000 | 0x00500000 | 0x01000000;
    uint32_t i;

    assert(read_mach(host) == (host & cpsr_user_mask));
    assert(read_mach(0xffffffff) == cpsr_user_mask);
    assert(read_frame(0xffffffff) == cpsr_user_mask);
    /* The server's capture reads as the thread's own save_context would. */
    assert(read_mach(host) == save(host));
    for (i = 0; i < 32; i++)
    {{
        /* NZCV and bit 21 (the x86 trap flag), what FEX writes and cpsr_to_eflags reads. */
        ULONG fex = ((i & 0xf) << 28) | ((i & 0x10) ? 1u << 21 : 0);
        assert(read_mach(fex | host) == save(fex | host));
        assert((read_mach(fex | (host & ~0xf0200000u)) & 0xf0200000u) == fex);
        /* A frame ntdll wrote (NtSetContextThread) reads back unchanged. */
        assert(read_frame(set_context(fex)) == fex);
        assert(read_frame(set_context(~fex)) == set_context(~fex));
    }}
    return 0;
}}
''')

if __name__ == "__main__":
    unittest.main()
