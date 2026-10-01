/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * selfcheck_test.c — selfcheck.c on the Linux host (pp test): the pool
 * placement rules at their edges, the order the checks run in, and the
 * report line the app logs as `title: selfcheck:` (tools/ui.py puts it in
 * the result event).
 */
#include "selfcheck.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static const unsigned long long MiB = 1ull << 20;

static selfcheck_facts good(void)
{
    selfcheck_facts f = {
        .page_size = 0x4000, .tsd_key = 284, .tsd_slot = 284, .pool = 1,
        .pool_rx = 0x119000000ull, .pool_rw = 0x7000000000ull, .pool_size = 896 * MiB, .alias_ok = 1,
    };
    return f;
}

int main(void)
{
    char r[512];

    /* Placement: the pool the phone gets today, and one below the old 0x119000000 floor. */
    CHECK(selfcheck_pool_placement(0x119000000ull, 896 * MiB) == SELFCHECK_OK);
    CHECK(selfcheck_pool_placement(0x102094000ull, 896 * MiB) == SELFCHECK_OK);
    CHECK(selfcheck_pool_placement(0x100000000ull, 16 * 1024) == SELFCHECK_OK);
    CHECK(selfcheck_pool_placement(0x0ffffc000ull, 896 * MiB) == SELFCHECK_POOL_LOW);
    CHECK(selfcheck_pool_placement(0x119002000ull, 896 * MiB) == SELFCHECK_POOL_ALIGN);
    CHECK(selfcheck_pool_placement(0x119000000ull, 896 * MiB + 0x1000) == SELFCHECK_POOL_ALIGN);
    CHECK(selfcheck_pool_placement(0x119000000ull, 0) == SELFCHECK_POOL_ALIGN);
    /* The last page StikJIT can address, and one past it. */
    CHECK(selfcheck_pool_placement(0x1000000000ull - 0x4000, 0x4000) == SELFCHECK_OK);
    CHECK(selfcheck_pool_placement(0x1000000000ull - 0x4000, 0x8000) == SELFCHECK_POOL_HIGH);
    CHECK(selfcheck_pool_placement(0xffffffffffffc000ull, 0x8000) == SELFCHECK_POOL_HIGH);   /* no wrap */
    /* debugserver's fallback when nothing low fits: the guest window, above 2^36 too. */
    CHECK(selfcheck_pool_placement(0x7000000000ull, 896 * MiB) == SELFCHECK_POOL_HIGH);

    /* A launch that passes. */
    selfcheck_facts f = good();
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_OK);
    CHECK(!strcmp(r, "ok page=16384 tsd=key 284 slot 284 pool=0x119000000+896MiB rw=0x7000000000"));

    /* The host part alone (before the pool is acquired). */
    f.pool = 0;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_OK);
    CHECK(!strcmp(r, "ok page=16384 tsd=key 284 slot 284"));

    /* Each failure names itself first and keeps the facts. */
    f = good();
    f.page_size = 4096;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_PAGE);
    CHECK(!strncmp(r, "failed page: the host page is 4096 bytes", 40));
    CHECK(strstr(r, "; page=4096 tsd=key 284 slot 284 pool=0x119000000+896MiB") != NULL);

    f = good();
    f.tsd_slot = -1;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_TSD);
    CHECK(!strncmp(r, "failed tsd: ", 12));
    f.tsd_slot = SELFCHECK_TSD_SLOTS;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_TSD);

    f = good();
    f.pool_rx = 0xff0000000ull;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_POOL_HIGH);
    CHECK(strstr(r, "failed pool-high: the pool ends at 0x1028000000, above 2^36") == r);

    f = good();
    f.alias_ok = 0;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_ALIAS);
    CHECK(!strncmp(r, "failed alias: ", 14));
    f = good();
    f.pool_rw = 0;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_ALIAS);

    /* The page is judged before the pool, so the report names the root cause. */
    f = good();
    f.page_size = 4096;
    f.pool_rx = 0x119002000ull;
    CHECK(selfcheck_judge(&f, r, sizeof(r)) == SELFCHECK_PAGE);

    /* A short buffer is cut, never overrun. */
    char small[16];
    memset(small, 'x', sizeof(small));
    f = good();
    CHECK(selfcheck_judge(&f, small, 8) == SELFCHECK_OK);
    CHECK(small[7] == 0 && small[8] == 'x');

    CHECK(!strcmp(selfcheck_name(SELFCHECK_POOL_GUEST), "pool-guest"));
    CHECK(!strcmp(selfcheck_name(99), "unknown"));

    if (failures) {
        printf("selfcheck_test: %d failure(s)\n", failures);
        return 1;
    }
    printf("selfcheck_test: ok\n");
    return 0;
}
