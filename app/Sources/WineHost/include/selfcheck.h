/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * selfcheck.h — the runtime's start-up self-check: the assumptions about the
 * host that a launch depends on, judged from facts the caller gathers
 * (wine_host_selfcheck on the phone, app/tests/selfcheck_test.c on Linux).
 * docs/ARCHITECTURE.md, "Start-up self-check".
 */
#ifndef PLAYPORT_SELFCHECK_H
#define PLAYPORT_SELFCHECK_H

#include <stddef.h>

/* The host page: StikJIT blesses the pool 16 KiB page by page
 * (ScriptRunner.jitPageSize, PAGE in playport-universal.js), and the pool's
 * base and size are multiples of it. */
#define SELFCHECK_PAGE_SIZE 0x4000ull
/* The pool's lowest address: iOS maps nothing below 4 GiB (__PAGEZERO), and
 * ntdll's fault triage takes a pc below it for a stray guest branch
 * (signal_arm64_ios.c), never for pool code. */
#define SELFCHECK_POOL_MIN 0x100000000ull
/* The pool's end: StikJIT sends each page's address as 9 hex digits
 * (ScriptRunner.makeBlessCommands), so a page at or above 2^36 would be
 * blessed at the wrong address. */
#define SELFCHECK_POOL_END_MAX 0x1000000000ull
/* The x86-64 guest window: Wine packs PE images there and the fault handlers
 * take a pc there for guest code; pool code there hangs its first call. */
#define SELFCHECK_GUEST_LO 0x7000000000ull
#define SELFCHECK_GUEST_HI 0x8000000000ull
/* ntdll finds the TEB's raw TSD slot by scanning this many (loader_ios.c). */
#define SELFCHECK_TSD_SLOTS 512

enum selfcheck_result {
    SELFCHECK_OK = 0,
    SELFCHECK_PAGE,        /* the host page is not 16 KiB */
    SELFCHECK_TSD,         /* a pthread key's value is not in a raw TSD slot off TPIDRRO_EL0 */
    SELFCHECK_POOL_ALIGN,  /* the pool's base or size is not a whole number of pages */
    SELFCHECK_POOL_LOW,    /* the pool starts below 4 GiB */
    SELFCHECK_POOL_HIGH,   /* the pool ends above 2^36 */
    SELFCHECK_POOL_GUEST,  /* the pool overlaps the guest window */
    SELFCHECK_ALIAS,       /* a word written through the RW alias does not read back through RX */
};

typedef struct {
    unsigned long long page_size;    /* the host's (vm_page_size) */
    int tsd_key;                     /* a fresh pthread key */
    int tsd_slot;                    /* the raw slot that held its value; -1 when none did */
    int pool;                        /* nonzero: the pool fields below are filled */
    unsigned long long pool_rx, pool_rw, pool_size;
    int alias_ok;                    /* the RW-to-RX readback matched */
} selfcheck_facts;

/* The short name of a result ("ok", "page", "tsd", "pool-align", ...). */
const char *selfcheck_name(int result);

/* The pool's placement alone, which wine_host_jit_pool_acquire also checks:
 * SELFCHECK_OK or the first rule it breaks. */
int selfcheck_pool_placement(unsigned long long rx, unsigned long long size);

/* Every assumption in turn: SELFCHECK_OK or the first that fails. report gets
 * one line, "ok page=16384 tsd=key 5 slot 5 pool=0x...+896MiB rw=0x..."; on a
 * failure it starts "failed <name>: <why>;" instead of "ok". Pool facts are
 * judged only when f->pool is set. */
int selfcheck_judge(const selfcheck_facts *f, char *report, size_t len);

#endif
