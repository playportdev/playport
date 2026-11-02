# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0268's pp_x64_syscall_stub.h (PLA-514): a native ARM64 child that calls an x86-64
system call stub of the ARM64EC ntdll (World of Warcraft calls NtProtectVirtualMemory in a copy of
system32\\ntdll.dll it reads from disk) gets the system call. The matcher must take Wine's stubs and nothing else, and
the stub numbers must be the aarch64 ntdll's numbers for the same functions, which the ILL handler passes to the
dispatcher. 0269 gives a native child's freed RWX memory its pool range back."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0268-signal-a-native-child-s-call-into-an-x86-64-syscall-.patch"
POOL_PATCH = ROOT / "patches/madeira-unix/0269-virtual-a-native-child-s-freed-RWX-memory-gives-its-.patch"
HEADER = "build/ntdll-unix/pp_x64_syscall_stub.h"

TEST_C = r'''
#include "pp_x64_syscall_stub.h"
#include <assert.h>
#include <string.h>

int main(void) {
    /* NtProtectVirtualMemory in the ARM64EC ntdll, RVA 0x8e520 (run 20261101T040227 called it at +0x8e520). */
    unsigned char stub[32] = { 0x4c, 0x8b, 0xd1, 0xb8, 0x50, 0x00, 0x00, 0x00, 0xf6, 0x04, 0x25, 0x08, 0x03, 0xfe,
                               0x7f, 0x01, 0x75, 0x03, 0x0f, 0x05, 0xc3, 0xcd, 0x2e, 0xc3 };
    unsigned char c[32];
    assert(PP_X64_SYSCALL_STUB_SIZE == 21);
    assert(pp_x64_syscall_stub_id(stub) == 0x50);
    /* The first word is the one the ILL handler checks before calling the matcher. */
    assert((stub[0] | stub[1] << 8 | stub[2] << 16 | (unsigned)stub[3] << 24) == 0xb8d18b4cu);
    /* A table-1 number (win32u) passes; one past 14 bits does not. */
    memcpy(c, stub, sizeof c); c[5] = 0x10; assert(pp_x64_syscall_stub_id(c) == 0x1050);
    memcpy(c, stub, sizeof c); c[5] = 0x40; assert(pp_x64_syscall_stub_id(c) == -1);
    memcpy(c, stub, sizeof c); c[7] = 0x01; assert(pp_x64_syscall_stub_id(c) == -1);
    /* Any other byte of the stub breaks the match: a hooked stub (jmp at the start) or another sequence. */
    for (int i = 0; i < PP_X64_SYSCALL_STUB_SIZE; i++) {
        if (i >= 4 && i < 8) continue;
        memcpy(c, stub, sizeof c); c[i] ^= 0x01; assert(pp_x64_syscall_stub_id(c) == -1);
    }
    memset(c, 0, sizeof c); assert(pp_x64_syscall_stub_id(c) == -1);
    return 0;
}
'''


class X64SyscallStubTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_both_ill_paths_enter_the_dispatcher(self):
        """The Mach handler (which delivers an ILL to the guest itself) and ill_handler (before its diagnostics) both
        ask ios_native_x64_stub and enter the dispatcher with x8 and x9 set as the aarch64 ntdll's own stub does
        (mov x8, #id; mov x9, x30; blr dispatcher). Run 20261101T042609 had the first call reach ill_handler and the
        second, in the same iteration, the Mach handler."""
        text = PATCH.read_text()
        self.assertIn("+        *(const uint32_t *)(uintptr_t)pc != 0xb8d18b4c || !ios_is_native_arm64_peb( peb )) "
                      "return -1;", text)
        # ill_handler
        self.assertIn("+            REGn_sig( 8, context ) = id;", text)
        self.assertIn("+            REGn_sig( 9, context ) = REGn_sig( 30, context );", text)
        self.assertIn("+            PC_sig( context ) = (ULONG_PTR)__wine_syscall_dispatcher;", text)
        sig = text.index('"SIGILL" );')
        self.assertLess(sig, text.index('ERR("ILL at pc=', sig))
        # the Mach handler, before its last-resort delivery
        self.assertIn("+            if (!handled && req->exception == EXC_BAD_INSTRUCTION && thread_teb)", text)
        self.assertIn("+                    state.__x[8] = id;", text)
        self.assertIn("+                    state.__x[9] = lr;", text)
        mach = text.index('((TEB *)thread_teb)->Peb, "Mach" );')
        self.assertLess(mach, text.index("ml369 (#63): last-resort", mach))

    def test_freed_rwx_returns_its_range(self):
        """A native child's alias retired whole returns its ledger range to the free list, through the insertion the
        exit-time reclaim uses, and the child's anonymous executable memory has a budget."""
        text = POOL_PATCH.read_text()
        self.assertIn("+        if (native && !pieces) ios_pool_return_anon_locked( old.jit_rw_alias, "
                      "old.user_va_end - old.user_va, old.peb );", text)
        self.assertIn("+        if (ios_pool_freelist_add_locked( off, size, poisoned ))", text)
        self.assertIn("+    if (!ios_pool_freelist_add_locked( off, size, poisoned )) return;", text)
        self.assertIn("(held = ios_jit_anon_bytes_of( ios_jit_current_peb() )) + alloc_size > jit_pool_size / 4)",
                      text)


if __name__ == "__main__":
    unittest.main()
