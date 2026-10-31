# SPDX-License-Identifier: GPL-3.0-or-later
"""The dev footprint-jump sampler's ledger reader (app/Sources/MemoryLedger, PLA-476): the exact
C source against a mock ledger() that serves XNU's template and entry records, or refuses."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

MOCK = r'''
#include "memory_ledger.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

struct tinfo { char name[32], group[32], units[32]; };
struct einfo { int64_t balance, credit, debit; uint64_t limit, period, last; };
static int refuse;
static const char *names[] = {"cpu_time", "phys_footprint", "page_table", "internal", "alternate_accounting", "iokit_mapped"};
static const int64_t mb[] = {7, 7072, 5, 5986, 2100, -1};

int ledger(int cmd, caddr_t a1, caddr_t a2, caddr_t a3)
{
    int n = (int)(sizeof(names) / sizeof(names[0]));
    if (cmd == 2) {                      /* LEDGER_TEMPLATE_INFO: records in a1, count in a2 */
        int *len = (int *)a2;
        assert(*len >= n);
        struct tinfo *t = (struct tinfo *)a1;
        for (int i = 0; i < n; i++) { memset(&t[i], 0, sizeof(t[i])); strcpy(t[i].name, names[i]); }
        *len = n;
        return 0;
    }
    assert(cmd == 1);                    /* LEDGER_ENTRY_INFO: pid in a1, records in a2, count in a3 */
    if (refuse) { errno = refuse; return -1; }
    int *len = (int *)a3;
    struct einfo *e = (struct einfo *)a2;
    for (int i = 0; i < n; i++) { memset(&e[i], 0, sizeof(e[i])); e[i].balance = mb[i] * (1 << 20); }
    *len = n;
    return 0;
}

int main(void)
{
    char out[512];
    assert(pp_memory_ledger_self(out, sizeof(out)) == 0);
    /* in the reader's order, only the entries it knows, in MB */
    assert(!strcmp(out, "phys_footprint=7072 internal=5986 alternate_accounting=2100 iokit_mapped=-1 page_table=5"));
    char small[20];
    assert(pp_memory_ledger_self(small, sizeof(small)) == 0);
    assert(strlen(small) < sizeof(small));
    refuse = EPERM;
    strcpy(out, "stale");
    assert(pp_memory_ledger_self(out, sizeof(out)) == EPERM);
    assert(out[0] == 0);
    puts("ok");
    return 0;
}
'''


class MemoryLedgerTests(unittest.TestCase):
    def test_reader_against_a_mock_ledger(self):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="memory-ledger-test-", dir=work) as tmp:
            root = Path(tmp)
            (root / "mock.c").write_text(MOCK)
            subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                            "-I", str(REPO / "app/Sources/MemoryLedger/include"),
                            str(root / "mock.c"), str(REPO / "app/Sources/MemoryLedger/memory_ledger.c"),
                            "-o", str(root / "test")], check=True)
            out = subprocess.run([str(root / "test")], check=True, capture_output=True, text=True).stdout
            self.assertEqual(out.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
