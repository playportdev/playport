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

    /* The executable window: the exec-time reservation (1440 MiB from the
     * executable's end, 0x103ea8000 to 0x10a3f8000 seen) keeps it above a
     * 512 or 768 MiB pool and its 64 MiB slack at every slide; 896 MiB keeps
     * it at the lowest slide only. */
    {
        const unsigned long long res = 1440 * MiB, slack = 64 * MiB;
        const unsigned long long slides[] = { 0x103ea8000ull, 0x10a3f8000ull };
        unsigned long long give[2][2];
        int held;
        for (int i = 0; i < 2; i++) {
            unsigned long long lo = slides[i], hi = lo + res;
            CHECK(hi >= SELFCHECK_EXE_WINDOW_HI);
            for (int p = 0; p < 2; p++) {
                unsigned long long freed = lo + (p ? 768 : 512) * MiB + slack;
                CHECK(selfcheck_exe_window_split(freed, hi, give, &held) == 2 && held);
                CHECK(give[0][0] == freed && give[0][1] == SELFCHECK_EXE_WINDOW_LO);
                CHECK(give[1][0] == SELFCHECK_EXE_WINDOW_HI && give[1][1] == hi);
            }
        }
        unsigned long long lo = slides[0], hi = lo + res;
        CHECK(selfcheck_exe_window_split(lo + 896 * MiB + slack, hi, give, &held) == 2 && held);
        lo = slides[1], hi = lo + res;
        CHECK(selfcheck_exe_window_split(lo + 896 * MiB + slack, hi, give, &held) == 1 && !held);
        CHECK(give[0][0] == lo + 896 * MiB + slack && give[0][1] == hi);
        /* The pool's range ending exactly at the window, and a reservation ending exactly at its top. */
        CHECK(selfcheck_exe_window_split(SELFCHECK_EXE_WINDOW_LO, SELFCHECK_EXE_WINDOW_HI, give, &held) == 0 && held);
        /* A reservation that stops short of the window's top keeps nothing. */
        CHECK(selfcheck_exe_window_split(0x120000000ull, SELFCHECK_EXE_WINDOW_HI - 0x4000, give, &held) == 1 && !held);
        /* Nothing left above the pool. */
        CHECK(selfcheck_exe_window_split(0x160000000ull, 0x160000000ull, give, &held) == 0 && !held);
    }

    CHECK(!strcmp(selfcheck_name(SELFCHECK_POOL_GUEST), "pool-guest"));
    CHECK(!strcmp(selfcheck_name(99), "unknown"));

    if (failures) {
        printf("selfcheck_test: %d failure(s)\n", failures);
        return 1;
    }
    printf("selfcheck_test: ok\n");
    return 0;
}
