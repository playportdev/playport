/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * selfcheck — see include/selfcheck.h.
 *
 * Plain C with no Apple headers, so the host C tests (`pp test`, app/tests)
 * can build and exercise it on the Linux host.
 */

#include "selfcheck.h"

#include <stdio.h>

const char *selfcheck_name(int result)
{
    switch (result) {
    case SELFCHECK_OK: return "ok";
    case SELFCHECK_PAGE: return "page";
    case SELFCHECK_TSD: return "tsd";
    case SELFCHECK_POOL_ALIGN: return "pool-align";
    case SELFCHECK_POOL_LOW: return "pool-low";
    case SELFCHECK_POOL_HIGH: return "pool-high";
    case SELFCHECK_POOL_GUEST: return "pool-guest";
    case SELFCHECK_ALIAS: return "alias";
    }
    return "unknown";
}

int selfcheck_pool_placement(unsigned long long rx, unsigned long long size)
{
    if (!size || (rx | size) & (SELFCHECK_PAGE_SIZE - 1)) return SELFCHECK_POOL_ALIGN;
    if (rx < SELFCHECK_POOL_MIN) return SELFCHECK_POOL_LOW;
    if (rx > SELFCHECK_POOL_END_MAX || size > SELFCHECK_POOL_END_MAX - rx) return SELFCHECK_POOL_HIGH;
    if (rx < SELFCHECK_GUEST_HI && rx + size > SELFCHECK_GUEST_LO) return SELFCHECK_POOL_GUEST;
    return SELFCHECK_OK;
}

int selfcheck_judge(const selfcheck_facts *f, char *report, size_t len)
{
    char why[160] = "";
    int rc = SELFCHECK_OK;
    if (f->page_size != SELFCHECK_PAGE_SIZE) {
        rc = SELFCHECK_PAGE;
        snprintf(why, sizeof(why), "the host page is %llu bytes; the JIT pool is blessed in 16 KiB pages",
                 f->page_size);
    } else if (f->tsd_slot < 0 || f->tsd_slot >= SELFCHECK_TSD_SLOTS) {
        rc = SELFCHECK_TSD;
        snprintf(why, sizeof(why), "pthread key %d's value is in none of the first %d TSD slots off TPIDRRO_EL0; "
                 "the translated code finds the TEB there", f->tsd_key, SELFCHECK_TSD_SLOTS);
    } else if (f->pool && (rc = selfcheck_pool_placement(f->pool_rx, f->pool_size)) != SELFCHECK_OK) {
        unsigned long long end = f->pool_rx + f->pool_size;
        switch (rc) {
        case SELFCHECK_POOL_ALIGN:
            snprintf(why, sizeof(why), "the pool 0x%llx+0x%llx is not in whole 16 KiB pages", f->pool_rx, f->pool_size);
            break;
        case SELFCHECK_POOL_LOW:
            snprintf(why, sizeof(why), "the pool starts at 0x%llx, below 4 GiB", f->pool_rx);
            break;
        case SELFCHECK_POOL_HIGH:
            snprintf(why, sizeof(why), "the pool ends at 0x%llx, above 2^36: StikJIT blesses a page by a "
                     "9-hex-digit address", end);
            break;
        default:
            snprintf(why, sizeof(why), "the pool 0x%llx-0x%llx overlaps the guest window [0x%llx, 0x%llx)",
                     f->pool_rx, end, SELFCHECK_GUEST_LO, SELFCHECK_GUEST_HI);
            break;
        }
    } else if (f->pool && (!f->pool_rw || !f->alias_ok)) {
        rc = SELFCHECK_ALIAS;
        snprintf(why, sizeof(why), "a word written through the RW alias 0x%llx did not read back through the pool "
                 "at 0x%llx; every JIT write goes that way", f->pool_rw, f->pool_rx);
    }

    int n = rc == SELFCHECK_OK ? snprintf(report, len, "ok")
                               : snprintf(report, len, "failed %s: %s;", selfcheck_name(rc), why);
    if (n < 0 || (size_t)n >= len) return rc;
    int m = snprintf(report + n, len - n, " page=%llu tsd=key %d slot %d", f->page_size, f->tsd_key, f->tsd_slot);
    if (m < 0 || (size_t)(n += m) >= len) return rc;
    if (f->pool)
        snprintf(report + n, len - n, " pool=0x%llx+%lluMiB rw=0x%llx", f->pool_rx, f->pool_size >> 20, f->pool_rw);
    return rc;
}
