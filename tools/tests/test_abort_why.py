# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0301's pp_abort_why.h (PLA-880): a host abort() on a game's thread becomes the
game's EXCEPTION_WINE_ASSERTION (0x80000101) with no reason, as The Witcher 3's dxvk-cs thread's did; the handler now
finds each image's crash-reporter annotations (the __crash_info section, in __DATA or the shared cache's __DATA_DIRTY),
reads their messages and walks the host frames above the abort."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0301-signal-a-host-abort-on-a-game-s-thread-logs-its-reas.patch"
HEADER = "build/ntdll-unix/pp_abort_why.h"

TEST_C = r'''
#include "pp_abort_why.h"
#include <assert.h>
#include <string.h>

static uint64_t image[512];
static uint64_t stack[64];

/* The test's stack: a frame inside it reads, any other address is refused */
static int read_stack(uint64_t addr, uint64_t frame[2], void *ctx)
{
    const uint64_t lo = (uint64_t)(uintptr_t)stack, hi = lo + sizeof(stack);
    (void)ctx;
    if (addr < lo || addr + 16 > hi) return 0;
    memcpy(frame, (const void *)(uintptr_t)addr, 16);
    return 1;
}

static int find(const char *name, intptr_t slide, uint64_t *addr, uint64_t *size)
{
    return ppaw_find_section(image, slide, name, addr, size);
}

int main(void) {
    /* A dylib as the shared cache lays it out: __TEXT,__text; an LC_UUID;
     * __DATA_DIRTY with __data and __crash_info */
    struct ppaw_mach_header *mh = (void *)image;
    unsigned char *p = (unsigned char *)(mh + 1);
    struct ppaw_segment *text = (void *)p;
    text->cmd = PPAW_LC_SEGMENT_64;
    text->cmdsize = sizeof(*text) + sizeof(struct ppaw_section);
    strcpy(text->segname, "__TEXT");
    text->nsects = 1;
    struct ppaw_section *s = (void *)(text + 1);
    strcpy(s->sectname, "__text");
    s->addr = 0x1000; s->size = 0x100;
    p += text->cmdsize;
    struct ppaw_load_command *uuid = (void *)p;
    uuid->cmd = 0x1b; uuid->cmdsize = 24;
    p += uuid->cmdsize;
    struct ppaw_segment *data = (void *)p;
    data->cmd = PPAW_LC_SEGMENT_64;
    data->cmdsize = sizeof(*data) + 2 * sizeof(struct ppaw_section);
    strcpy(data->segname, "__DATA_DIRTY");
    data->nsects = 2;
    s = (void *)(data + 1);
    strcpy(s[0].sectname, "__data");
    s[0].addr = 0x8000; s[0].size = 0x40;
    memcpy(s[1].sectname, "__crash_info", 12);  /* 16 bytes, no NUL needed */
    s[1].addr = 0x8040; s[1].size = 64;
    p += data->cmdsize;
    mh->magic = PPAW_MH_MAGIC_64;
    mh->ncmds = 3;
    mh->sizeofcmds = (uint32_t)(p - (unsigned char *)(mh + 1));

    uint64_t addr = 0, size = 0;
    assert(find("__crash_info", 0x2000000, &addr, &size) && addr == 0x2008040 && size == 64);
    assert(find("__text", 0, &addr, &size) && addr == 0x1000 && size == 0x100);
    assert(!find("__crash_inf", 0, &addr, &size) && !find("__objc_data", 0, &addr, &size));
    /* Malformed: a command past sizeofcmds, a cmdsize of 0, more sections than
     * the command holds, not a 64-bit image */
    mh->sizeofcmds -= 8;
    assert(!find("__crash_info", 0, &addr, &size));
    mh->sizeofcmds += 8;
    uuid->cmdsize = 0;
    assert(!find("__crash_info", 0, &addr, &size));
    uuid->cmdsize = 24;
    data->nsects = 3;
    assert(!find("__crash_info", 0, &addr, &size));
    data->nsects = 2;
    mh->magic = 0xfeedfaceu;
    assert(!find("__crash_info", 0, &addr, &size));
    mh->magic = PPAW_MH_MAGIC_64;
    assert(find("__crash_info", 0, &addr, &size) && addr == 0x8040);
    assert(!ppaw_find_section(NULL, 0, "__crash_info", &addr, &size));

    /* An annotation: a message (Metal's failed assertion, say), a second one
     * and an abort cause (version 5) */
    struct ppaw_crash_info info = {5, 0x1000, 0, 0, 0x2000, 0, 0, 7};
    uint64_t msgs[2], cause;
    assert(ppaw_crash_messages(&info, sizeof(info), msgs, &cause) == 2 &&
           msgs[0] == 0x1000 && msgs[1] == 0x2000 && cause == 7);
    info.version = 4;
    assert(ppaw_crash_messages(&info, sizeof(info), msgs, &cause) == 2 && !cause);
    /* A section that holds only the version and the message */
    assert(ppaw_crash_messages(&info, 16, msgs, &cause) == 1 && msgs[0] == 0x1000);
    info.message = 0;
    assert(ppaw_crash_messages(&info, sizeof(info), msgs, &cause) == 1 && msgs[0] == 0x2000);
    /* Never filled (version 0), or too short to hold a message */
    info.version = 0; info.message = 0x1000;
    assert(ppaw_crash_messages(&info, sizeof(info), msgs, &cause) == 0);
    info.version = 5;
    assert(ppaw_crash_messages(&info, 8, msgs, &cause) == 0);

    /* Frames: three up the stack, the last with no caller */
    const uint64_t base = (uint64_t)(uintptr_t)stack;
    uint64_t ret[8];
    stack[4] = base + 10 * 8; stack[5] = 0x1a0000004;
    stack[10] = base + 20 * 8; stack[11] = 0x1a0000008;
    stack[20] = 0; stack[21] = 0x1a000000c;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 3 &&
           ret[0] == 0x1a0000004 && ret[1] == 0x1a0000008 && ret[2] == 0x1a000000c);
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 2) == 2);
    /* A frame naming itself, a caller below its callee, a jump past
     * PPAW_FRAME_MAX, a caller the reader refuses: each ends the walk */
    stack[10] = base + 10 * 8;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 2);
    stack[10] = base + 2 * 8;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 2);
    stack[10] = base + 10 * 8 + PPAW_FRAME_MAX + 8;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 2);
    stack[10] = base + 63 * 8;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 2);
    /* A misaligned or null fp, and a return address of 0 */
    assert(ppaw_walk(base + 4 * 8 + 4, read_stack, NULL, ret, 8) == 0);
    assert(ppaw_walk(0, read_stack, NULL, ret, 8) == 0);
    stack[5] = 0;
    assert(ppaw_walk(base + 4 * 8, read_stack, NULL, ret, 8) == 0);
    return 0;
}
'''


class AbortWhyTests(unittest.TestCase):
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

    def test_the_handler_uses_it(self):
        """abrt_handler logs a host abort before it adopts it as the game's exception; the annotations come from every
        image's __crash_info and are read with mach_vm_read_overwrite; the release app (MADEIRA_NO_DIAGNOSTICS) stays
        quiet."""
        patch = PATCH.read_text()
        self.assertIn("+    ios_log_host_abort( (ucontext_t *)sigcontext );\n #endif\n     setup_exception( sigcontext, &rec );",
                      patch)
        self.assertIn('+        if (!ppaw_find_section( _dyld_get_image_header( i ), _dyld_get_image_vmaddr_slide( i ),\n'
                      '+                                "__crash_info", &addr, &size ))', patch)
        self.assertIn('+    if (said++ || getenv( "MADEIRA_NO_DIAGNOSTICS" )) return;', patch)
        self.assertIn("+    n = 2 + ppaw_walk( FP_sig( context ), ios_abort_read_frame, NULL, ret + 2, 22 );", patch)
        self.assertEqual(patch.count("+        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)"), 2)


if __name__ == "__main__":
    unittest.main()
