/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_MEMORY_LEDGER_H
#define PLAYPORT_MEMORY_LEDGER_H
#include <stddef.h>
/* Dev builds only (PLA-476): this task's memory ledger entries, read with the
 * private ledger() syscall that footprint(1) uses: phys_footprint's terms that
 * TASK_VM_INFO lacks (alternate_accounting, iokit_mapped, page_table and the
 * rest). Writes `name=MB` words for the entries it knows into report and
 * returns 0, or returns errno (or -1) when the kernel or the sandbox refuses;
 * report is then empty. Untested on iOS: the dev sampler logs its first return
 * code. */
int pp_memory_ledger_self(char *report, size_t capacity);
#endif
