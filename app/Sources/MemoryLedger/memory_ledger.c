/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "memory_ledger.h"
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

/* XNU's bsd/sys/ledger.h (private): the commands and their records. */
enum { LEDGER_ENTRY_INFO = 1, LEDGER_TEMPLATE_INFO = 2, LEDGER_NAME_MAX = 32 };
struct ledger_template_info {
    char lti_name[LEDGER_NAME_MAX], lti_group[LEDGER_NAME_MAX], lti_units[LEDGER_NAME_MAX];
};
struct ledger_entry_info {
    int64_t lei_balance, lei_credit, lei_debit;
    uint64_t lei_limit, lei_refill_period, lei_last_refill;
};
/* Exported by libsystem_kernel (the iOS SDK's libSystem stub lists _ledger). */
extern int ledger(int cmd, caddr_t arg1, caddr_t arg2, caddr_t arg3);

/* The entries phys_footprint is made of, and the tags beside them. */
static const char *const wanted[] = {
    "phys_footprint", "internal", "internal_compressed", "alternate_accounting",
    "alternate_accounting_compressed", "iokit_mapped", "page_table", "purgeable_nonvolatile",
    "purgeable_nonvolatile_compressed", "tagged_footprint", "tagged_footprint_compressed",
    "network_nonvolatile", "media_footprint", "neural_footprint", "wired_mem", "phys_mem",
};

int pp_memory_ledger_self(char *report, size_t capacity)
{
    enum { MAX = 256 };
    struct ledger_template_info templates[MAX];
    struct ledger_entry_info entries[MAX];
    int names = MAX, count = MAX, rc = 0;
    struct sigaction old, ignore;

    if (capacity) report[0] = 0;
    /* A kernel without the call answers with SIGSYS, which would end the app: ignore it
     * for the call when nothing handles it, so the call returns ENOSYS instead. */
    memset(&ignore, 0, sizeof(ignore));
    ignore.sa_handler = SIG_IGN;
    int guard = sigaction(SIGSYS, NULL, &old) == 0 && !(old.sa_flags & SA_SIGINFO) && old.sa_handler == SIG_DFL;
    if (guard) sigaction(SIGSYS, &ignore, NULL);
    errno = 0;
    if (ledger(LEDGER_TEMPLATE_INFO, (caddr_t)templates, (caddr_t)&names, NULL) != 0
        || ledger(LEDGER_ENTRY_INFO, (caddr_t)(intptr_t)getpid(), (caddr_t)entries, (caddr_t)&count) != 0)
        rc = errno ? errno : -1;
    if (guard) sigaction(SIGSYS, &old, NULL);
    if (rc) return rc;
    if (names > MAX) names = MAX;
    if (count > names) count = names;

    size_t used = 0;
    for (size_t w = 0; w < sizeof(wanted) / sizeof(wanted[0]); w++) {
        for (int i = 0; i < count; i++) {
            if (strncmp(templates[i].lti_name, wanted[w], LEDGER_NAME_MAX)) continue;
            int n = snprintf(report + used, capacity - used, "%s%s=%lld", used ? " " : "", wanted[w],
                             (long long)(entries[i].lei_balance / (1 << 20)));
            if (n < 0 || (size_t)n >= capacity - used) return 0;
            used += (size_t)n;
            break;
        }
    }
    return 0;
}
