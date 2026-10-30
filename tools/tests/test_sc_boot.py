# SPDX-License-Identifier: GPL-3.0-or-later
"""Boot holds: all-or-nothing, no takeover without the host ownership marker."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def header(patch, name):
    section = patch.read_text().split(f'diff --git a/build/ntdll-unix/{name}', 1)[1]
    section = section.split('diff --git ', 1)[0]
    return '\n'.join(line[1:] for line in section.splitlines()
                     if line.startswith('+') and not line.startswith('+++')) + '\n'


TEST = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef uint64_t mach_vm_address_t;
#define VM_FLAGS_FIXED 0
#define MEMORY_OBJECT_NULL 0
#define PROT_NONE 0
#define VM_PROT_ALL 7
#define VM_INHERIT_COPY 1
#define KERN_SUCCESS 0
static uintptr_t ios_jumbo_hold_base;
static size_t ios_jumbo_hold_size, ios_jumbo_hold_keep;
static int calls, fail_at, freed;
static uint64_t freed_base[8];
static int mach_task_self(void) { return 1; }
static int mach_vm_map(int task, uint64_t *a, uint64_t size, int mask, int flags,
                       int object, int offset, int copy, int prot, int max, int inherit) {
    (void)task; (void)a; (void)size; (void)mask; (void)object; (void)offset;
    (void)copy; (void)max; (void)inherit;
    assert(flags == VM_FLAGS_FIXED && prot == PROT_NONE);
    return ++calls == fail_at ? 1 : KERN_SUCCESS;
}
static int mach_vm_deallocate(int task, uint64_t a, uint64_t size) {
    (void)task; (void)size;
    assert(freed < 8);
    freed_base[freed++] = a;
    return 0;
}
#include "pp_sc_boot.h"
static void reset(void) {
    calls = fail_at = freed = ppsc_ready = ppsc_held = 0;
    ios_jumbo_hold_base = ios_jumbo_hold_size = ios_jumbo_hold_keep = 0;
    unsetenv("PLAYPORT_SC_LAYOUT");
    unsetenv("WINE_IOS_SC_LOW_HELD");
    unsetenv("WINE_IOS_JIT_RW");
    unsetenv("WINE_IOS_JIT_SIZE");
}
static void configure(void) {
    setenv("PLAYPORT_SC_LAYOUT", "1", 1);
    setenv("WINE_IOS_SC_LOW_HELD", "1", 1);
    setenv("WINE_IOS_JIT_RW", "7900000000", 1);
    setenv("WINE_IOS_JIT_SIZE", "38000000", 1);
}
int main(void) {
    reset(); ppsc_boot(); assert(!calls && !freed && !ppsc_ready && !ppsc_requested);
    reset(); configure(); setenv("PLAYPORT_SC_LAYOUT", "0", 1);
    ppsc_boot(); assert(!calls && !freed && !ppsc_ready && !ppsc_requested);
    /* Requested but not ready: virtual_init refuses the launch. */
    reset(); configure(); unsetenv("WINE_IOS_SC_LOW_HELD");
    ppsc_boot(); assert(!calls && !freed && !ppsc_ready && ppsc_requested);
    reset(); configure(); setenv("WINE_IOS_JIT_RW", "7000000000", 1);
    ppsc_boot(); assert(!calls && !freed && !ppsc_ready);
    reset(); configure(); setenv("WINE_IOS_JIT_SIZE", "100000001", 1);
    ppsc_boot(); assert(!calls && !freed && !ppsc_ready);
    reset(); configure(); ppsc_boot();
    assert(ppsc_ready && ppsc_requested && calls == 6 && !freed);
    assert(ios_jumbo_hold_base == PPSC_GAME_BASE && ios_jumbo_hold_size == PPSC_GAME_SIZE);
    assert(!getenv("WINE_IOS_SC_LOW_HELD"));
    for (int failure = 1; failure <= 6; failure++) {
        reset(); configure(); fail_at = failure; ppsc_boot();
        assert(!ppsc_ready && ppsc_requested && !ppsc_held && !ios_jumbo_hold_size);
        /* Successful calls plus the one host-owned slot, never the failed slot. */
        assert(calls == failure && freed == failure);
        int low = 0;
        for (int i = 0; i < freed; i++) low += freed_base[i] == ppsc_range(PPSC_CEF).base;
        assert(low == 1);
    }
    reset(); configure(); ios_jumbo_hold_size = 123;
    ppsc_boot(); assert(!ppsc_ready && freed == 6 && ios_jumbo_hold_size == 123);
    return 0;
}
'''


class SocialClubBootTests(unittest.TestCase):
    def test_owned_boot_holds(self):
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            for number, name in [('0224-ntdll-social-club-layout-geometry.patch', 'pp_sc_layout.h'),
                                 ('0225-ntdll-social-club-boot-layout.patch', 'pp_sc_boot.h')]:
                (d / name).write_text(header(ROOT / 'patches/madeira-unix' / number, name))
            (d / 'test.c').write_text(TEST)
            subprocess.run([shutil.which('cc'), '-D_GNU_SOURCE', '-std=c11', '-Wall', '-Wextra',
                            '-Werror', '-fsanitize=undefined', str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True)

    def test_incomplete_boot_refuses_launch(self):
        text = (ROOT / 'patches/madeira-unix/0225-ntdll-social-club-boot-layout.patch').read_text()
        hunk = text.split('+    ppsc_boot();', 1)[1].split('\n@@', 1)[0]
        self.assertIn('+    if (ppsc_requested && !ppsc_ready)', hunk)
        self.assertIn('launch refused', hunk)
        self.assertIn('+        exit(1);', hunk)
