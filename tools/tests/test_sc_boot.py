# SPDX-License-Identifier: GPL-3.0-or-later
"""Boot holds: the Social Club layout's anchors only (madeira-unix 0299), all-or-nothing, no takeover
without the host ownership marker."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UNIX = ROOT / 'patches/madeira-unix'
HEADERS = [('0224-ntdll-social-club-layout-geometry.patch', 'pp_sc_layout.h'),
           ('0225-ntdll-social-club-boot-layout.patch', 'pp_sc_boot.h')]
LATER = ['0236-ntdll-refuse-the-Social-Club-helper-s-impossible-V8-.patch',
         '0299-ntdll-the-Social-Club-layout-holds-only-its-anchors-.patch']


def header(patch, name):
    section = patch.read_text().split(f'diff --git a/build/ntdll-unix/{name}', 1)[1]
    section = section.split('diff --git ', 1)[0]
    return '\n'.join(line[1:] for line in section.splitlines()
                     if line.startswith('+') and not line.startswith('+++')) + '\n'


def series_headers(d):
    """HEADERS as the series leaves them, under d/build/ntdll-unix."""
    unix = d / 'build/ntdll-unix'
    unix.mkdir(parents=True)
    for patch, name in HEADERS:
        (unix / name).write_text(header(UNIX / patch, name))
    # d is inside this repository's .work: keep git apply from treating it as one.
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(d.parent))
    include = [f'--include=build/ntdll-unix/{name}' for _, name in HEADERS]
    for patch in LATER:
        subprocess.run(['git', 'apply', *include, str(UNIX / patch)], cwd=d, env=env, check=True)
    return unix


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
static int calls, fail_at, freed;
static uint64_t freed_base[8];
static char log_text[4096];
#define dprintf(fd, ...) ((void)(fd), snprintf(log_text + strlen(log_text), sizeof log_text - strlen(log_text), __VA_ARGS__))
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
    log_text[0] = 0;
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
    /* The RW alias may not reach the cage's home at 0x7a00000000: fail closed. */
    reset(); configure(); setenv("WINE_IOS_JIT_SIZE", "100000001", 1);
    ppsc_boot(); assert(!calls && !freed && !ppsc_ready && ppsc_requested);
    assert(strstr(log_text, "RW alias 0x7900000000+0x100000001 reaches the cage's home at 0x7a00000000"));
    reset(); configure(); setenv("WINE_IOS_JIT_SIZE", "100000000", 1);
    ppsc_boot(); assert(ppsc_ready && calls == 3);
    reset(); configure(); ppsc_boot();
    /* Three native anchor holds (libcef's is the host's); nothing else. */
    assert(ppsc_ready && ppsc_requested && calls == 3 && !freed);
    assert(ppsc_held == PPSC_ANCHORS);
    assert(!getenv("WINE_IOS_SC_LOW_HELD"));
    assert(strstr(log_text, "anchors held: libcef 0x7000000000+0x4000000 (from exec), ELF_META 0x7400000000+0x40000000, "
                            "chrome_elf 0x7800000000+0x4000000, Oilpan 0x7c00000000+0x20000000; FEX floor 0x7c20000000;"));
    for (int failure = 1; failure <= 3; failure++) {
        reset(); configure(); fail_at = failure; ppsc_boot();
        assert(!ppsc_ready && ppsc_requested && !ppsc_held);
        /* Successful calls plus the one host-owned slot, never the failed slot. */
        assert(calls == failure && freed == failure);
        int low = 0;
        for (int i = 0; i < freed; i++) low += freed_base[i] == ppsc_range(PPSC_CEF).base;
        assert(low == 1);
    }
    return 0;
}
'''


class SocialClubBootTests(unittest.TestCase):
    def test_owned_boot_holds(self):
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = series_headers(pathlib.Path(td))
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
