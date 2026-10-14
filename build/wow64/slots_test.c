/* A WoW64 window's fixed slots (madeira-unix 0146, wow64_slots.h), compiled
 * from the patch: the slots sit 4 GB apart below the ceiling's margin, stop at
 * the floor, an occupied slot is skipped, and the bases do not depend on what
 * else is mapped outside them.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "wow64_slots.h"

#define CEILING UINT64_C(0x73ffff0000)
#define FLOOR UINT64_C(0x7048000000)

/* A fake address space: [lo, hi) ranges that are mapped. */
struct space { unsigned int n; uint64_t lo[8], hi[8]; unsigned int tries; };

static int try_slot( uintptr_t base, void *ctx )
{
    struct space *s = ctx;
    s->tries++;
    for (unsigned int i = 0; i < s->n; i++)
        if (base < s->hi[i] && base + IOS_WOW64_WINDOW_SIZE > s->lo[i]) return 0;
    s->lo[s->n] = base;
    s->hi[s->n++] = base + IOS_WOW64_WINDOW_SIZE;
    return 1;
}

int main(void)
{
    const uintptr_t slot0 = CEILING - IOS_WOW64_SLOT_MARGIN - IOS_WOW64_WINDOW_SIZE;
    unsigned int k;

    /* The bases: 64K-aligned, 4 GB apart, inside [floor, ceiling - margin). */
    assert( slot0 == UINT64_C(0x72bfff0000) );
    assert( ios_wow64_slot_base( CEILING, FLOOR, 0 ) == slot0 );
    assert( ios_wow64_slot_base( CEILING, FLOOR, 1 ) == slot0 - IOS_WOW64_WINDOW_SIZE );
    assert( ios_wow64_slot_base( CEILING, FLOOR, 2 ) == slot0 - 2 * IOS_WOW64_WINDOW_SIZE );
    assert( ios_wow64_slot_base( CEILING, FLOOR, 3 ) == 0 );   /* would reach below the floor */
    for (k = 0; ios_wow64_slot_base( CEILING, FLOOR, k ); k++)
    {
        uintptr_t base = ios_wow64_slot_base( CEILING, FLOOR, k );
        assert( ios_wow64_valid_base( base ) && base >= FLOOR );
        assert( base + IOS_WOW64_WINDOW_SIZE <= CEILING - IOS_WOW64_SLOT_MARGIN );
    }
    assert( k == 3 );
    /* No slot: a ceiling under its margin, a floor above every slot, no wrap. */
    assert( !ios_wow64_slot_base( IOS_WOW64_SLOT_MARGIN, 0, 0 ) );
    assert( !ios_wow64_slot_base( CEILING, CEILING, 0 ) );
    assert( !ios_wow64_slot_base( UINTPTR_MAX, 0, UINT32_MAX ) );
    for (k = 0; k < 70; k++)
        assert( !ios_wow64_slot_base( UINTPTR_MAX, 0, k ) ||
                ios_wow64_valid_base( ios_wow64_slot_base( UINTPTR_MAX, 0, k ) ) );

    /* A launcher, then its child: slots 0 and 1 whatever else is mapped below
     * them (the furniture that moved Assassin's Creed's child). */
    for (uint64_t furniture = 0; furniture < UINT64_C(0x60000000); furniture += UINT64_C(0x1220000))
    {
        struct space s = { 3, { 0x7000000000, FLOOR, CEILING - 0x3200000 },
                              { FLOOR, FLOOR + 0x1000000 + furniture, CEILING }, 0 };
        assert( ios_wow64_reserve_slot( CEILING, FLOOR, try_slot, &s ) == slot0 );
        assert( ios_wow64_reserve_slot( CEILING, FLOOR, try_slot, &s ) == slot0 - IOS_WOW64_WINDOW_SIZE );
    }
    /* An occupied slot is skipped; with none free the caller places it as before. */
    {
        struct space s = { 1, { slot0 + 0x10000 }, { slot0 + 0x20000 }, 0 };
        assert( ios_wow64_reserve_slot( CEILING, FLOOR, try_slot, &s ) == slot0 - IOS_WOW64_WINDOW_SIZE );
        assert( ios_wow64_reserve_slot( CEILING, FLOOR, try_slot, &s ) == slot0 - 2 * IOS_WOW64_WINDOW_SIZE );
        s.tries = 0;
        assert( ios_wow64_reserve_slot( CEILING, FLOOR, try_slot, &s ) == 0 );
        assert( s.tries == 3 );
    }
    puts("WoW64 window slots: checked bases, margin, floor, occupied slots and stable placement");
    return 0;
}
