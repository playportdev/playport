/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "wow64_window.h"

static void test_window( uintptr_t base )
{
    static const uint32_t edges[] = {0, 1, 0xffff, 0x10000, 0x400000,
                                    0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff};
    uint32_t out;
    assert( ios_wow64_valid_base( base ) );
    for (unsigned int i = 0; i < sizeof(edges) / sizeof(edges[0]); i++)
    {
        uintptr_t host = ios_wow64_host_addr( base, edges[i] );
        assert( host == (edges[i] ? base + edges[i] : 0) );
        out = 0xdeadbeef;
        assert( ios_wow64_guest_addr( base, host, &out ) && out == edges[i] );
    }
    /* The guard's base must not be confused with the null sentinel. */
    const uintptr_t bad[] = {1, base - 1, base, base + IOS_WOW64_WINDOW_SIZE, UINTPTR_MAX};
    for (unsigned int i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
    {
        out = 0xdeadbeef;
        assert( !ios_wow64_guest_addr( base, bad[i], &out ) );
        assert( out == 0xdeadbeef );
    }
    assert( !ios_wow64_guest_addr( base, base + 0x400000, NULL ) );
    /* Wider inputs cannot sneak in through inverse truncation. */
    out = 0xdeadbeef;
    assert( !ios_wow64_guest_addr( base, base + UINT64_C(0x100400000), &out ) );
    assert( out == 0xdeadbeef );
    /* Property coverage beyond the explicit boundaries. */
    uint32_t guest = 0x12345678;
    for (unsigned int i = 0; i < 100000; i++)
    {
        guest = guest * 1664525u + 1013904223u;
        assert( ios_wow64_guest_addr( base, ios_wow64_host_addr( base, guest ), &out ) );
        assert( out == guest );
    }
}

int main(void)
{
    const uintptr_t a = UINT64_C(0x7400000000), b = UINT64_C(0x7500000000);
    uint32_t out = 0xdeadbeef;
    test_window( a );
    test_window( b );
    assert( ios_wow64_host_addr( a, 0x400000 ) != ios_wow64_host_addr( b, 0x400000 ) );
    assert( !ios_wow64_guest_addr( b, ios_wow64_host_addr( a, 0x400000 ), &out ) );
    assert( out == 0xdeadbeef );
    const uintptr_t bad_bases[] = {0, 0x10000, 0xffffffff, a + 1, UINTPTR_MAX - 0xffff};
    for (unsigned int i = 0; i < sizeof(bad_bases) / sizeof(bad_bases[0]); i++)
    {
        assert( !ios_wow64_valid_base( bad_bases[i] ) );
        assert( !ios_wow64_host_addr( bad_bases[i], 0x400000 ) );
        assert( !ios_wow64_guest_addr( bad_bases[i], 0, &out ) );
    }
    puts("WoW64 window: checked round trips, null, guard offsets, edges, overflow and owner separation");
    return 0;
}
