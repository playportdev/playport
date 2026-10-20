# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0174's pp_async_iosb.h (PLA-364): an async I/O's status block is written at
any address, Information first, then Status (the Rockstar Games Launcher's cloud-save upload completes with one at an
odd address, where ARM64's release store faults)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0174-ntdll-write-an-async-I-O-s-status-block-at-any-addre.patch"
HEADER = "build/ntdll-unix/pp_async_iosb.h"

TEST_C = r'''
#include "pp_async_iosb.h"
#include <assert.h>

struct iosb64 { uint32_t status; uint32_t pad; uint64_t information; };
struct iosb32 { uint32_t status; uint32_t information; };

int main(void) {
    unsigned char buf[64];
    for (unsigned off = 0; off < 16; off++) {
        uint32_t s; uint64_t i64; uint32_t i32;
        unsigned char *p = buf + off;
        memset(buf, 0xee, sizeof(buf));
        pp_iosb_store(p, p + 8, 8, 0xc0000005u, 0x123456789abcdefull);
        memcpy(&s, p, 4); memcpy(&i64, p + 8, 8);
        assert(s == 0xc0000005u && i64 == 0x123456789abcdefull);
        assert(p[4] == 0xee && p[7] == 0xee && (off == 0 || buf[off - 1] == 0xee) && p[16] == 0xee);

        memset(buf, 0xee, sizeof(buf));
        pp_iosb_store(p, p + 4, 4, 0x103u, 0xffffffff00000040ull);   /* WoW64: a 32-bit Information */
        memcpy(&s, p, 4); memcpy(&i32, p + 4, 4);
        assert(s == 0x103u && i32 == 0x40u && p[8] == 0xee);
    }
    return 0;
}
'''


class AsyncIosbTests(unittest.TestCase):
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
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-fsanitize=alignment",
                            "-fno-sanitize-recover=all", "-I", str((d / HEADER).parent), "-o", str(d / "t"),
                            str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_the_async_io_apc_uses_it(self):
        text = PATCH.read_text()
        self.assertIn("+            ios_set_async_iosb( call->async_io.sb, result->async_io.status, info );", text)


if __name__ == "__main__":
    unittest.main()
