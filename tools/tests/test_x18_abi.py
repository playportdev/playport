# SPDX-License-Identifier: GPL-3.0-or-later
"""The custom x18 ABI probe (PLA-516): madeira-unix 0272's pp_x18_abi.h and the dir-arm64 probe's x18 phase.

With madeira.cfg x18-abi = 1 a native ARM64 child's thread calls macOS 26.4's os_set_custom_x18_abi_enabled as it
starts. The call traps when asked for the state the thread is in, and jumps through update_tpidr, which is NULL when
the kernel passed no commpage address (xnu libsyscall/os/x18.c): the header must call it only when neither holds, and
say what it found. The probe reads x18 only by stores relative to SP and writes it by MOV; the runtime's x18 patcher
(0263) must leave every such word of the probe alone, or the probe would read the TEB the trampoline loads."""
import pathlib
import re
import subprocess
import tempfile
import unittest

from test_x18_compare import patcher
from test_x18_x64_code import ROOT, UPSTREAM, patched_source

PATCH = ROOT / "patches/madeira-unix/0272-signal-madeira.cfg-x18-abi-turns-on-the-custom-x18-A.patch"
HEADER = "build/ntdll-unix/pp_x18_abi.h"
PROBE = ROOT / "tools/compat/probes/arm64.c"

HEADER_TEST_C = r'''
#include "pp_x18_abi.h"
#include <assert.h>
#include <string.h>

static uint64_t tpidr = 0x5;          /* a CPU number in the low bits */
static int set_calls, have_set = 1, have_get = 1, have_update = 1;
static void fake_update(uint64_t v) { tpidr = v; }
static void (*update_tpidr)(uint64_t) = fake_update;

static bool fake_get(void) { return (tpidr & PP_X18_ABI_TPIDR_BIT) != 0; }
static void fake_set(bool on)
{
    set_calls++;
    assert(on != fake_get());          /* the real one traps here */
    assert(update_tpidr);              /* and jumps to 0 here */
    errno = 0;
    update_tpidr(on ? tpidr | PP_X18_ABI_TPIDR_BIT : tpidr & ~PP_X18_ABI_TPIDR_BIT);
}
static void *lookup(const char *name)
{
    if (!strcmp(name, "os_set_custom_x18_abi_enabled")) return have_set ? (void *)fake_set : NULL;
    if (!strcmp(name, "os_custom_x18_abi_enabled")) return have_get ? (void *)fake_get : NULL;
    if (!strcmp(name, "update_tpidr")) return have_update ? (void *)&update_tpidr : NULL;
    return NULL;
}
static uint64_t read_tpidr(void) { return tpidr; }

int main(void)
{
    struct pp_x18_abi_result r;
    char line[512];

    /* Off: called once, the bit set, the CPU bits kept. */
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_CALLED);
    assert(set_calls == 1 && !r.before && r.after && r.set_fn == (void *)fake_set && r.update_tpidr);
    assert(r.tpidr_before == 0x5 && r.tpidr_after == (0x5 | PP_X18_ABI_TPIDR_BIT));
    pp_x18_abi_describe(&r, line, sizeof(line));
    assert(!strncmp(line, "called: ", 8));
    assert(strstr(line, "enabled 0 -> 1, TPIDR_EL0 0x5 -> 0x1000000000005 (bit 48 0 -> 1), errno"));

    /* On already: a second enable would trap, so no call. */
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_ALREADY_ON);
    assert(set_calls == 1 && r.before && r.after);
    pp_x18_abi_describe(&r, line, sizeof(line));
    assert(!strncmp(line, "already on: ", 12));

    /* No commpage routine: the call would jump to 0. */
    tpidr = 0x5;
    update_tpidr = NULL;
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_NO_UPDATE);
    assert(set_calls == 1 && !r.update_tpidr);
    update_tpidr = fake_update;
    have_update = 0;
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_NO_UPDATE);
    assert(set_calls == 1);
    pp_x18_abi_describe(&r, line, sizeof(line));
    assert(!strncmp(line, "no update_tpidr: ", 17));
    have_update = 1;

    /* Not exported: nothing called. */
    have_set = 0;
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_MISSING);
    have_set = 1, have_get = 0;
    assert(pp_x18_abi_enable(lookup, read_tpidr, &r) == PP_X18_ABI_MISSING);
    assert(set_calls == 1 && !r.get_fn);
    pp_x18_abi_describe(&r, line, sizeof(line));
    assert(!strncmp(line, "missing: ", 9));
    return 0;
}
'''

ROLE_TEST_C = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define ERR(...) ((void)0)
int ios_teb_tls_slot_offset = 0x940;
long ios_limit_x18_images, ios_limit_x18_sites;
#include "patcher.c"

int main(void)
{
    /* The probe's words that touch x18 (llvm-mingw 20260922's encoding of arm64.c's asm). */
    static const uint32_t probe[] = {
        0xf90013f2,   /* str x18, [sp, #32]: x18_run keeps the entry x18 */
        0xaa0103f2,   /* mov x18, x1: the sentinel */
        0xf90017f2,   /* str x18, [sp, #40]: x18 after op */
        0xf94013f2,   /* ldr x18, [sp, #32]: the entry x18 back */
        0xf81f0ff2,   /* str x18, [sp, #-16]!: x18_read */
        0xd53bd049,   /* mrs x9, tpidr_el0 */
        0xd51bd049,   /* msr tpidr_el0, x9 */
        0xd4001001,   /* svc #0x80 */
        0x0000dead,   /* udf #0xdead */
    };
    for (unsigned i = 0; i < sizeof(probe) / sizeof(probe[0]); i++)
        if (ios_insn_x18_role(probe[i]) != X18_ROLE_NONE) { printf("patched %08x\n", probe[i]); return 1; }
    /* The classifier itself still takes a read of x18 into another register. */
    assert(ios_insn_x18_role(0xaa1203e0) != X18_ROLE_NONE);   /* mov x0, x18 */
    assert(ios_insn_x18_role(0xf9000a52) != X18_ROLE_NONE);   /* str x18, [x18, #16] */
    return 0;
}
'''


class X18AbiHeaderTests(unittest.TestCase):
    def test_header_calls_only_when_safe(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".work") as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.c").write_text(HEADER_TEST_C)
            subprocess.run(["clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_thread_start_wiring(self):
        """Off unless madeira.cfg says x18-abi = 1, native ARM64 children only, at the end of every thread's
        init_syscall_frame, on the thread itself, after the Mach exception handler has it."""
        text = PATCH.read_text()
        self.assertIn('+    if (wanted < 0) wanted = madeira_cfg_bool( "x18-abi", 0 );', text)
        self.assertIn("+    if (!wanted || !ios_is_native_arm64_peb( teb->Peb )) return;", text)
        self.assertIn("+    return dlsym( RTLD_DEFAULT, name );", text)
        self.assertIn('+    dprintf( 2, "[x18-abi] tid %04x teb %p: %s (PLA-516)\\n",', text)
        self.assertRegex(text, r"@@ [^@]+ @@ void init_syscall_frame\( LPTHREAD_START_ROUTINE entry, void \*arg, "
                               r"TEB \*teb \)\n(?: .*\n)+\+#ifdef WINE_IOS\n\+    pp_x18_abi_thread_start\( teb \);\n"
                               r"\+#endif\n \n     pthread_sigmask\( SIG_UNBLOCK, &server_block_set, NULL \);\n }\n")


class X18AbiProbeTests(unittest.TestCase):
    @unittest.skipUnless(UPSTREAM.exists(), "upstream/madeira is not checked out")
    def test_patcher_leaves_the_probe_alone(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".work") as td:
            tmp = pathlib.Path(td)
            (tmp / "patcher.c").write_text(patcher(patched_source(tmp / "tree")))
            (tmp / "test.c").write_text(ROLE_TEST_C)
            exe = tmp / "t"
            subprocess.run(["clang", "-std=gnu11", "-O1", "-w", "-o", str(exe), str(tmp / "test.c")], check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_probe_asm_is_the_tested_words(self):
        """The words above are the probe's: its asm reads x18 by these SP-relative stores only."""
        src = PROBE.read_text()
        asm = src[src.index('__asm__(\n    ".text\\n"'):src.index("#define X18_SENTINEL")]
        lines = [m.group(1) for m in re.finditer(r'"([^"]*?)(?:\\n\\t|\\n)"', asm)]
        x18 = sorted({line.strip() for line in lines if re.search(r"\bx18\b", line)})
        self.assertEqual(x18, ["ldr x18, [sp, #32]", "mov x18, x1", "str x18, [sp, #-16]!", "str x18, [sp, #32]",
                               "str x18, [sp, #40]"])

    def test_phase_is_opt_in_and_leaves_the_exit_code(self):
        src = PROBE.read_text()
        self.assertIn('    if (strstr(cmdline, "x18")) x18_phase();\n', src)
        phase = src[src.index("static void x18_phase(void)"):src.index("int WINAPI WinMain")]
        self.assertNotIn("failed", phase)
        self.assertNotIn("check(", phase)
        self.assertIn('probe_log("x18-abi: %s; plain: %s; armed: %s\\n"', phase)


if __name__ == "__main__":
    unittest.main()
